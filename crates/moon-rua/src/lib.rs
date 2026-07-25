//! In-process Rua compilation, module loading and traceback rendering.

use moon_runtime::loader::{LuaChunk, LuaErrorContext, LuaErrorReporter, LuaModuleLoader};
use rua_common::embedded_std;
use ruac::{
    artifact::{bundle_sidecar_path, modules_manifest_path, read_manifest, source_hash},
    codegen::{GeneratedLuaModule, GeneratedLuaModules, LuaSourceMapping},
    stacktrace::{RuaStackFrame, convert_lua_frame, parse_lua_traceback},
};
use std::{
    collections::{BTreeMap, BTreeSet},
    fs,
    path::{Path, PathBuf},
    sync::Arc,
};

#[derive(Clone)]
struct RuntimeChunk {
    source: Arc<[u8]>,
    name: Arc<str>,
    source_text: Arc<str>,
    source_map: Arc<[LuaSourceMapping]>,
    source_files: Arc<[String]>,
}

/// Registry used by Moon's Lua states to load Rua modules from memory.
pub struct RuaRuntime {
    modules: BTreeMap<String, Arc<RuntimeChunk>>,
    entries: BTreeMap<String, Arc<RuntimeChunk>>,
    chunks: BTreeMap<String, Arc<RuntimeChunk>>,
}

impl RuaRuntime {
    /// Build a runtime registry from a modules artifact and its root `.rua` path.
    pub fn from_modules(
        artifact: GeneratedLuaModules,
        root_source: impl Into<String>,
    ) -> Result<Arc<Self>, String> {
        let source_files = Arc::<[String]>::from(artifact.source_files);
        let mut modules = BTreeMap::new();
        let mut entries = BTreeMap::new();
        let mut chunks = BTreeMap::new();

        for module in &artifact.modules {
            let chunk = Arc::new(runtime_chunk(module, source_files.clone()));
            let chunk_name = chunk.name.to_string();
            let output_path = module.output_path.clone();
            let module_name = module.module_name.clone();
            modules.insert(module_name.clone(), chunk.clone());
            chunks.insert(chunk_name.clone(), chunk.clone());
            chunks.insert(normalize_chunk_name(&chunk_name), chunk.clone());
            entries.insert(format!("rua://{module_name}"), chunk.clone());
            entries.insert(output_path, chunk.clone());
            let source_ids = module
                .source_map
                .iter()
                .map(|mapping| mapping.source.file)
                .collect::<BTreeSet<_>>();
            for source_id in source_ids {
                if let Some(source_path) = source_files.get(source_id as usize) {
                    entries.insert(source_path.clone(), chunk.clone());
                }
            }
        }

        let root_source = root_source.into();
        let root_key = root_source.trim_start_matches("@").to_string();
        let root_module = artifact
            .modules
            .iter()
            .find(|module| module.is_root)
            .map(|module| module.module_name.clone())
            .ok_or_else(|| "Rua modules artifact has no root module".to_string())?;
        let root = modules
            .get(&root_module)
            .cloned()
            .ok_or_else(|| format!("Rua root module `{root_module}` is missing"))?;
        entries.insert(root_source, root.clone());
        entries.insert(root_key, root);

        if let Ok(std) = embedded_std() {
            if let Some(source) = std
                .runtime_sources()
                .iter()
                .find(|source| source.name() == "rua_std.lua")
            {
                let source_text = Arc::<str>::from(source.text());
                let chunk = Arc::new(RuntimeChunk {
                    source: Arc::<[u8]>::from(source_text.as_bytes().to_vec()),
                    name: Arc::<str>::from("@rua://rua_std.lua"),
                    source_text,
                    source_map: Arc::from([]),
                    source_files: Arc::from([]),
                });
                modules.insert("rua_std".to_string(), chunk.clone());
                chunks.insert("@rua://rua_std.lua".to_string(), chunk.clone());
                chunks.insert("rua://rua_std.lua".to_string(), chunk);
            }
        }

        Ok(Arc::new(Self {
            modules,
            entries,
            chunks,
        }))
    }

    /// Load a versioned artifact manifest and its generated Lua files without
    /// invoking `ruac`. The caller's entry path is retained for diagnostics and
    /// is also registered as an alias for the root chunk.
    pub fn from_manifest(
        manifest_path: &Path,
        root_source: impl Into<String>,
    ) -> Result<Arc<Self>, String> {
        let manifest = read_manifest(manifest_path)?;
        let base = manifest_path.parent().unwrap_or_else(|| Path::new("."));
        let mut modules = Vec::with_capacity(manifest.files.len());
        for file in &manifest.files {
            let path = base.join(&file.output_path);
            let source = fs::read_to_string(&path)
                .map_err(|error| format!("reading {}: {error}", path.display()))?;
            let actual_hash = source_hash(&source);
            if actual_hash != file.source_hash {
                return Err(format!(
                    "Rua artifact source hash mismatch for {}: manifest {}, actual {}",
                    path.display(),
                    file.source_hash,
                    actual_hash
                ));
            }
            modules.push(GeneratedLuaModule {
                module_name: file.module_name.clone(),
                output_path: file.output_path.clone(),
                source,
                source_map: file.source_map.clone(),
                is_root: file.is_root,
            });
        }
        let artifact = GeneratedLuaModules {
            root_output_path: manifest.root_output_path,
            modules,
            source_files: manifest.source_files,
            annotations: ruac::annotations::AnnotationIndex::default(),
        };
        Self::from_modules(artifact, root_source)
    }

    fn chunk_for_frame(&self, source: &str) -> Option<&Arc<RuntimeChunk>> {
        self.chunks
            .get(source)
            .or_else(|| self.chunks.get(&normalize_chunk_name(source)))
    }

    fn format_frame(&self, frame: ruac::stacktrace::LuaStackFrame) -> String {
        let Some(chunk) = self.chunk_for_frame(&frame.source) else {
            return frame.raw;
        };
        let converted = convert_lua_frame(
            frame,
            &chunk.source_text,
            &chunk.source_map,
            &chunk.source_files,
        );
        render_frame(&converted)
    }
}

impl LuaModuleLoader for RuaRuntime {
    fn load_entry(&self, source: &str) -> Option<LuaChunk> {
        self.entries.get(source).map(to_lua_chunk)
    }

    fn load_module(&self, module: &str) -> Option<LuaChunk> {
        self.modules.get(module).map(to_lua_chunk)
    }
}

impl LuaErrorReporter for RuaRuntime {
    fn format_error(&self, context: &LuaErrorContext, raw: &str) -> String {
        let parsed = parse_lua_traceback(raw);
        if parsed.frames.is_empty() {
            return raw.to_string();
        }
        let mut output = String::new();
        if !parsed.message.is_empty() {
            output.push_str(&parsed.message);
        }
        output.push_str(&format!(
            "\nRua stack (actor '{}' phase {:?}):",
            context.actor_name, context.phase
        ));
        for frame in parsed.frames {
            output.push_str("\n  ");
            output.push_str(&self.format_frame(frame));
        }
        output
    }
}

fn runtime_chunk(module: &GeneratedLuaModule, source_files: Arc<[String]>) -> RuntimeChunk {
    let name = format!("@rua://{}", module.output_path);
    RuntimeChunk {
        source: Arc::<[u8]>::from(module.source.as_bytes().to_vec()),
        name: Arc::<str>::from(name),
        source_text: Arc::<str>::from(module.source.clone()),
        source_map: Arc::from(module.source_map.clone()),
        source_files,
    }
}

fn to_lua_chunk(chunk: &Arc<RuntimeChunk>) -> LuaChunk {
    LuaChunk {
        source: chunk.source.clone(),
        name: chunk.name.clone(),
    }
}

fn normalize_chunk_name(source: &str) -> String {
    source.strip_prefix('@').unwrap_or(source).to_string()
}

fn render_frame(frame: &RuaStackFrame) -> String {
    match (&frame.rua_file, frame.rua_range) {
        (Some(file), Some(range)) => format!("{}:{} (Lua: {})", file, range.line, frame.lua.raw),
        _ => frame.lua.raw.clone(),
    }
}

/// Compile a `.rua` tree directly into a Moon runtime registry.
pub fn compile_path(path: &Path) -> Result<Arc<RuaRuntime>, String> {
    let artifact = ruac::compile_path_modules_artifact(path).map_err(|error| error.to_string())?;
    RuaRuntime::from_modules(artifact, path.to_string_lossy().into_owned())
}

/// Locate and load a precompiled artifact for an entry Lua file.
///
/// Bundle output uses `<entry>.rua-map.json`; module output uses the shared
/// `rua-artifact.json` in the entry directory. A plain Lua file returns `None`
/// so Moon can keep its existing Lua fallback behavior.
pub fn try_load_precompiled(path: &Path) -> Result<Option<Arc<RuaRuntime>>, String> {
    let manifest = locate_manifest(path)?;
    let Some(manifest) = manifest else {
        return Ok(None);
    };
    Ok(Some(RuaRuntime::from_manifest(
        &manifest,
        path.to_string_lossy(),
    )?))
}

fn locate_manifest(path: &Path) -> Result<Option<PathBuf>, String> {
    let sidecar = bundle_sidecar_path(path);
    if sidecar.is_file() {
        return Ok(Some(sidecar));
    }
    let directory = path.parent().unwrap_or_else(|| Path::new("."));
    let manifest = modules_manifest_path(directory);
    if !manifest.is_file() {
        return Ok(None);
    }
    let root = read_manifest(&manifest)?.root_output_path;
    Ok(
        (path.file_name().and_then(|name| name.to_str()) == Some(root.as_str()))
            .then_some(manifest),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use moon_runtime::loader::{LuaErrorPhase, LuaModuleLoader};
    use ruac::{annotations::AnnotationIndex, artifact::write_modules, token::SourceRange};
    use std::fs;

    fn runtime() -> Arc<RuaRuntime> {
        let source = "error(\"boom\")\n".to_string();
        let artifact = GeneratedLuaModules {
            root_output_path: "main.lua".to_string(),
            modules: vec![GeneratedLuaModule {
                module_name: "main".to_string(),
                output_path: "main.lua".to_string(),
                source: source.clone(),
                source_map: vec![LuaSourceMapping {
                    generated_start: 0,
                    generated_end: source.len(),
                    source: SourceRange {
                        start: 0,
                        len: 5,
                        line: 4,
                        file: 0,
                    },
                }],
                is_root: true,
            }],
            source_files: vec!["main.rua".to_string()],
            annotations: AnnotationIndex::default(),
        };
        RuaRuntime::from_modules(artifact, "main.rua").unwrap()
    }

    #[test]
    fn resolves_entry_and_module_from_memory() {
        let runtime = runtime();
        assert_eq!(
            runtime.load_entry("rua://main").unwrap().name.as_ref(),
            "@rua://main.lua"
        );
        assert!(runtime.load_entry("main.rua").is_some());
        assert_eq!(
            runtime.load_module("main").unwrap().source.as_ref(),
            b"error(\"boom\")\n"
        );
    }

    #[test]
    fn renders_mapped_and_unmapped_frames() {
        let runtime = runtime();
        let context = LuaErrorContext {
            actor_id: 1,
            actor_name: "bootstrap".to_string(),
            source: "rua://main".to_string(),
            phase: LuaErrorPhase::Init,
        };
        let rendered = runtime.format_error(
            &context,
            "lua: @rua://main.lua:1: boom\nstack traceback:\n\t@rua://main.lua:1: in main chunk\n\t[C]: in ?\n",
        );
        assert!(rendered.contains("main.rua:4"));
        assert!(rendered.contains("[C]: in ?"));
    }

    #[test]
    fn loads_precompiled_modules_and_rejects_stale_lua() {
        let directory =
            std::env::temp_dir().join(format!("moon-rua-artifact-{}", std::process::id()));
        let _ = fs::remove_dir_all(&directory);
        fs::create_dir_all(&directory).unwrap();
        let artifact = GeneratedLuaModules {
            root_output_path: "main.lua".to_string(),
            modules: vec![GeneratedLuaModule {
                module_name: "main".to_string(),
                output_path: "main.lua".to_string(),
                source: "return { value = 42 }\n".to_string(),
                source_map: Vec::new(),
                is_root: true,
            }],
            source_files: vec!["main.rua".to_string()],
            annotations: AnnotationIndex::default(),
        };
        write_modules(&directory, &artifact).unwrap();
        let entry = directory.join("main.lua");
        let runtime = try_load_precompiled(&entry).unwrap().unwrap();
        assert_eq!(
            runtime.load_entry("main.lua").unwrap().source.as_ref(),
            b"return { value = 42 }\n"
        );

        fs::write(&entry, "return { value = 7 }\n").unwrap();
        let error = match try_load_precompiled(&entry) {
            Err(error) => error,
            Ok(_) => panic!("stale artifact unexpectedly loaded"),
        };
        assert!(error.contains("source hash mismatch"), "{error}");
        fs::remove_dir_all(directory).unwrap();
    }
}

# contextListFolders

A PowerShell directory-tree lister with both human-readable and machine-readable output. Prints a Unicode tree of folders/files with sizes, and can export to JSON, NDJSON, CSV, and Markdown.

## Quick Start

```powershell
# Interactive mode — prompts for depth and options
.\contextListFolders.ps1

# Scan current directory, depth 2
.\contextListFolders.ps1 -Depth 2

# Scan a specific path, depth 3, export JSON + Markdown
.\contextListFolders.ps1 -Path C:\MyProject -Depth 3 -OutJson tree.json -MarkdownPath tree.md

# Filter to specific extensions
.\contextListFolders.ps1 -Depth 2 -Extensions .ps1,.md,.py

# Exclude common dev directories
.\contextListFolders.ps1 -Depth 3 -Exclude node_modules,.git,dist

# List output instead of tree
.\contextListFolders.ps1 -Depth 2 -Output List

# Full pipeline: all exports + passthru objects
.\contextListFolders.ps1 -Path . -Depth 3 -OutJson tree.json -OutCsv tree.csv -MarkdownPath tree.md -NdJson -PassThru
```

## Interactive Mode

When you run the script **without** `-Depth`, it enters interactive mode:

1. **Depth prompt** — enter a number 0–100 (default: 1)
2. **Mode selection**:
   - **Enter** — quick scan with defaults
   - **C** — open the configuration menu (toggle files, hidden items, ASCII mode, extensions, excludes, exports)
   - **D** — developer preset (auto-excludes `node_modules`, `.git`, `__pycache__`, etc.)
   - **F** — full export preset (enables Markdown, JSON, CSV, and tree-text output)

## Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `-Path` | string | `.` | Root path to scan |
| `-Depth` | int | 1 | Levels deep (0 = root only, max 100) |
| `-IncludeFiles` | bool | `$true` | Show files (use `-IncludeFiles:$false` for folders only) |
| `-IncludeHidden` | switch | off | Include hidden/system items |
| `-Include` | string[] | — | Wildcard patterns to include |
| `-Exclude` | string[] | — | Wildcard patterns to exclude |
| `-Extensions` | string[] | — | File extensions to include (e.g. `.py`, `.md`) |
| `-Output` | string | `Tree` | Console output: `Tree`, `List`, or `None` |
| `-UseAscii` | switch | off | ASCII tree chars instead of Unicode |
| `-OutJson` | string | — | Export JSON array to file |
| `-NdJson` | switch | off | Emit NDJSON (one JSON object per line) to pipeline |
| `-OutCsv` | string | — | Export CSV to file |
| `-OutTree` | string | — | Export tree text to file |
| `-MarkdownPath` | string | — | Export Markdown report to file |
| `-MarkdownTimestamp` | switch | off | Auto-name a timestamped Markdown file |
| `-PassThru` | switch | off | Return item objects to the pipeline |

## Output Schema

Each item (JSON/CSV/PassThru) contains:

```
Type, Name, FullName, RelativePath, Level, SizeBytes, Size,
Extension, IsHidden, LastWriteTime, CreationTime, Attributes
```

## License

MIT

# OpenrelikWorkerCommon

Elixir port of the Python [`openrelik-worker-common`](https://github.com/openrelik/openrelik-worker-common) library, providing shared functionality for [OpenRelik](https://github.com/openrelik) workers.

It is 100% wire-compatible with the Python OpenRelik ecosystem (Celery task results, base64-encoded JSON payloads, output file descriptors, and Markdown/JSON file and task reports).

## Modules

| Elixir Module | Python Source Equivalent | Responsibility |
|---|---|---|
| `OpenrelikWorkerCommon.DataTypes` | `openrelik_worker_common.data_types` | Standard OpenRelik data type constants (`diskimage:qcow`, `diskimage:raw`, `binary`) |
| `OpenrelikWorkerCommon.FileUtils` | `openrelik_worker_common.file_utils` | Output file creation (`OutputFile`), line counting, relative paths, file trees, and disk image detection |
| `OpenrelikWorkerCommon.TaskUtils` | `openrelik_worker_common.task_utils` | Input file filtering (glob patterns on filenames, paths, mime types, data types) and base64-encoded Celery task results |
| `OpenrelikWorkerCommon.Reporting` | `openrelik_worker_common.reporting` | Structured `Report`, `Priority`, `MarkdownDocument`, `MarkdownDocumentSection`, `MarkdownTable`, and `serialize_file_report/3` |
| `OpenrelikWorkerCommon.ArchiveUtils` | `openrelik_worker_common.archive_utils` | Archive extraction (`tar`, `tar.gz`, `tgz`, `zip`) with command log capture and export filename prefixing |
| `OpenrelikWorkerCommon.PasswordUtils` | `openrelik_worker_common.password_utils` | Password hash bruteforcing via `hashcat` and John the Ripper (`john` for `$y$` yescrypt hashes) |
| `OpenrelikWorkerCommon.MountUtils` | `openrelik_worker_common.mount_utils` | `BlockDevice` mounting for raw, QCOW2 (`qemu-nbd` + Redis NBD lock), and EWF/E01 (`ewfmount`) images |

## Installation

Add `openrelik_worker_common` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:openrelik_worker_common, "~> 0.1.0"}
  ]
end
```

## Usage Examples

### Creating Output Files & Task Results

```elixir
alias OpenrelikWorkerCommon.FileUtils
alias OpenrelikWorkerCommon.TaskUtils

# Filter input files matching desired criteria
files =
  TaskUtils.get_input_files(
    pipe_result,
    input_files,
    %{
      data_types: ["*:raw", "binary"],
      filenames: ["*.img", "*.bin"],
      mime_types: ["application/octet-stream"]
    }
  )

# Create an OutputFile with a unique UUID path
output_file =
  FileUtils.create_output_file(output_path,
    display_name: "results.txt",
    extension: "txt",
    data_type: "text:plain",
    source_file_id: 1
  )

File.write!(output_file.path, "extracted findings\n")

# Encode task result as base64 JSON for OpenRelik pipeline consumption
result_payload =
  TaskUtils.create_task_result(
    output_files: [FileUtils.OutputFile.to_dict(output_file)],
    workflow_id: workflow_id,
    command: "strings -a input.bin"
  )
```

### Generating Structured Markdown Reports

```elixir
alias OpenrelikWorkerCommon.Reporting.{Priority, Report}

{report, section} =
  Report.new("Strings Analyzer Report")
  |> Report.put_summary("Analyzed binary file and found 2 suspicious indicators.")
  |> Report.put_priority(Priority.high())
  |> Report.add_section()

{_section, table} =
  section
  |> OpenrelikWorkerCommon.Reporting.MarkdownDocumentSection.add_header("Indicators", level: 2)
  |> OpenrelikWorkerCommon.Reporting.MarkdownDocumentSection.add_table(["Indicator", "Offset"])

table =
  table
  |> OpenrelikWorkerCommon.Reporting.MarkdownTable.add_row(["http://malicious.example", "0x1040"])
  |> OpenrelikWorkerCommon.Reporting.MarkdownTable.add_row(["cmd.exe /c", "0x2080"])
```

## Running Tests

```bash
mix test
```

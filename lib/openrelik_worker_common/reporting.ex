# Copyright 2024 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

defmodule OpenrelikWorkerCommon.Reporting.Priority do
  @moduledoc """
  Reporting priority enum to store common values (`IntEnum` equivalent).

  Priorities can be anything in the range of 0-100, where 100 is the highest priority.
  """

  @critical 80
  @high 40
  @medium 20
  @low 10
  @info 5

  @type t :: integer() | atom()

  @doc "Returns `80` (`Priority.CRITICAL`)."
  @spec critical() :: integer()
  def critical, do: @critical

  @doc "Returns `40` (`Priority.HIGH`)."
  @spec high() :: integer()
  def high, do: @high

  @doc "Returns `20` (`Priority.MEDIUM`)."
  @spec medium() :: integer()
  def medium, do: @medium

  @doc "Returns `10` (`Priority.LOW`)."
  @spec low() :: integer()
  def low, do: @low

  @doc "Returns `5` (`Priority.INFO`)."
  @spec info() :: integer()
  def info, do: @info

  @doc "Converts a priority atom or integer into its integer value."
  @spec value(t()) :: integer()
  def value(v) when is_integer(v), do: v
  def value(:CRITICAL), do: @critical
  def value(:critical), do: @critical
  def value(:HIGH), do: @high
  def value(:high), do: @high
  def value(:MEDIUM), do: @medium
  def value(:medium), do: @medium
  def value(:LOW), do: @low
  def value(:low), do: @low
  def value(:INFO), do: @info
  def value(:info), do: @info
  def value(%{value: val}) when is_integer(val), do: val
end

defmodule OpenrelikWorkerCommon.Reporting.MarkdownFormatter do
  @moduledoc """
  Formats strings into Markdown elements (`openrelik_worker_common.reporting.MarkdownFormatter`).
  """

  @type t :: %__MODULE__{}
  defstruct []

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Formats text as bold in Markdown format."
  @spec bold(String.t()) :: String.t()
  def bold(text) when is_binary(text) do
    "**#{String.trim(text)}**"
  end

  @spec bold(t(), String.t()) :: String.t()
  def bold(%__MODULE__{}, text), do: bold(text)

  @doc "Formats text as a heading in Markdown format (level 1..5)."
  @spec heading(String.t(), integer()) :: String.t()
  def heading(text, level \\ 2)

  def heading(text, level) when is_binary(text) and is_integer(level) do
    if level < 1 or level > 5 do
      raise ArgumentError, "Heading level must be between 1 and 5"
    end

    "#{String.duplicate("#", level)} #{String.trim(text)}"
  end

  @spec heading(t(), String.t(), integer()) :: String.t()
  def heading(%__MODULE__{}, text, level), do: heading(text, level)

  @doc "Creates an H1 heading to use as page title."
  @spec title(String.t()) :: String.t()
  def title(text) when is_binary(text), do: heading(text, 1)

  @spec title(t(), String.t()) :: String.t()
  def title(%__MODULE__{}, text), do: heading(text, 1)

  @doc "Formats text as a bullet in Markdown format."
  @spec bullet(String.t(), integer()) :: String.t()
  def bullet(text, level \\ 1)

  def bullet(text, level) when is_binary(text) and is_integer(level) do
    indent = String.duplicate("    ", max(level - 1, 0))
    "#{indent}* #{String.trim(text)}"
  end

  @spec bullet(t(), String.t(), integer()) :: String.t()
  def bullet(%__MODULE__{}, text, level), do: bullet(text, level)

  @doc "Formats text as inline code in Markdown format."
  @spec code(String.t()) :: String.t()
  def code(text) when is_binary(text) do
    "`#{String.trim(text)}`"
  end

  @spec code(t(), String.t()) :: String.t()
  def code(%__MODULE__{}, text), do: code(text)

  @doc "Formats text as a code block in Markdown format."
  @spec code_block(String.t()) :: String.t()
  def code_block(text) when is_binary(text) do
    "```\n#{String.trim(text)}\n```"
  end

  @spec code_block(t(), String.t()) :: String.t()
  def code_block(%__MODULE__{}, text), do: code_block(text)

  @doc "Formats text as a paragraph of text in Markdown format."
  @spec paragraph(String.t()) :: String.t()
  def paragraph(text) when is_binary(text) do
    "\n#{String.trim(text)}\n"
  end

  @spec paragraph(t(), String.t()) :: String.t()
  def paragraph(%__MODULE__{}, text), do: paragraph(text)

  @doc "Formats text as a blockquote of text in Markdown format."
  @spec blockquote(String.t()) :: String.t()
  def blockquote(text) when is_binary(text) do
    "> #{String.trim(text)}\n"
  end

  @spec blockquote(t(), String.t()) :: String.t()
  def blockquote(%__MODULE__{}, text), do: blockquote(text)

  @doc "Formats a horizontal rule in Markdown format."
  @spec horizontal_rule() :: String.t()
  def horizontal_rule do
    "\n---\n"
  end

  @spec horizontal_rule(t()) :: String.t()
  def horizontal_rule(%__MODULE__{}), do: horizontal_rule()
end

defmodule OpenrelikWorkerCommon.Reporting.MarkdownTable do
  @moduledoc """
  Represents a Markdown table (`openrelik_worker_common.reporting.MarkdownTable`).
  """

  @type t :: %__MODULE__{
          columns: [String.t()],
          rows: [[String.t()]]
        }

  @enforce_keys [:columns]
  defstruct columns: [], rows: []

  @doc "Initializes a `MarkdownTable` struct with the given column names."
  @spec new([String.t()]) :: t()
  def new(columns) when is_list(columns) do
    %__MODULE__{columns: Enum.map(columns, &to_string/1), rows: []}
  end

  @doc """
  Adds a row of data to the table.

  Raises `ArgumentError` if the number of elements in `row_data` does not match `table.columns`.
  """
  @spec add_row(t(), [String.t()]) :: t()
  def add_row(%__MODULE__{columns: columns, rows: rows} = table, row_data)
      when is_list(row_data) do
    if length(row_data) != length(columns) do
      raise ArgumentError, "Number of columns in row data does not match table columns."
    end

    %{table | rows: rows ++ [Enum.map(row_data, &to_string/1)]}
  end

  @doc "Generates a Markdown representation of the table."
  @spec to_markdown(t()) :: String.t()
  def to_markdown(%__MODULE__{columns: columns, rows: rows}) do
    header = "|" <> Enum.join(columns, "|") <> "|\n"
    sep = "|" <> Enum.map_join(columns, "|", fn _ -> "---" end) <> "|\n"

    body =
      Enum.map_join(rows, "", fn row ->
        "|" <> Enum.join(row, "|") <> "|\n"
      end)

    "\n" <> header <> sep <> body
  end

  defimpl String.Chars do
    def to_string(table), do: OpenrelikWorkerCommon.Reporting.MarkdownTable.to_markdown(table)
  end
end

defmodule OpenrelikWorkerCommon.Reporting.MarkdownDocumentSection do
  @moduledoc """
  Represents a section of a Markdown document
  (`openrelik_worker_common.reporting.MarkdownDocumentSection`).
  """

  alias OpenrelikWorkerCommon.Reporting.MarkdownFormatter
  alias OpenrelikWorkerCommon.Reporting.MarkdownTable

  @type t :: %__MODULE__{
          content: [String.t()],
          fmt: MarkdownFormatter.t()
        }

  defstruct content: [], fmt: %MarkdownFormatter{}

  @doc "Initializes a `MarkdownDocumentSection` struct."
  @spec new() :: t()
  def new, do: %__MODULE__{content: [], fmt: %MarkdownFormatter{}}

  @doc "Adds a header to the section."
  @spec add_header(t(), String.t(), keyword() | integer()) :: t()
  def add_header(%__MODULE__{} = section, text, opts_or_level \\ 2) do
    level =
      cond do
        is_integer(opts_or_level) -> opts_or_level
        is_list(opts_or_level) -> Keyword.get(opts_or_level, :level, 2)
        true -> 2
      end

    append(section, MarkdownFormatter.heading(text, level))
  end

  @doc "Adds a bullet point to the section."
  @spec add_bullet(t(), String.t(), keyword() | integer()) :: t()
  def add_bullet(%__MODULE__{} = section, text, opts_or_level \\ 1) do
    level =
      cond do
        is_integer(opts_or_level) -> opts_or_level
        is_list(opts_or_level) -> Keyword.get(opts_or_level, :level, 1)
        true -> 1
      end

    append(section, MarkdownFormatter.bullet(text, level))
  end

  @doc "Adds text formatted as inline code to the section."
  @spec add_code(t(), String.t()) :: t()
  def add_code(%__MODULE__{} = section, text) do
    append(section, MarkdownFormatter.code(text))
  end

  @doc "Adds text formatted as a code block to the section."
  @spec add_code_block(t(), String.t()) :: t()
  def add_code_block(%__MODULE__{} = section, text) do
    append(section, MarkdownFormatter.code_block(text))
  end

  @doc "Adds text formatted as a paragraph to the section."
  @spec add_paragraph(t(), String.t()) :: t()
  def add_paragraph(%__MODULE__{} = section, text) do
    append(section, MarkdownFormatter.paragraph(text))
  end

  @doc "Adds text formatted as a blockquote to the section."
  @spec add_blockquote(t(), String.t()) :: t()
  def add_blockquote(%__MODULE__{} = section, text) do
    append(section, MarkdownFormatter.blockquote(text))
  end

  @doc "Adds a horizontal rule to the section."
  @spec add_horizontal_rule(t()) :: t()
  def add_horizontal_rule(%__MODULE__{} = section) do
    append(section, MarkdownFormatter.horizontal_rule())
  end

  @doc "Adds a `MarkdownTable` to the section."
  @spec add_table(t(), MarkdownTable.t()) :: t()
  def add_table(%__MODULE__{} = section, %MarkdownTable{} = table) do
    append(section, MarkdownTable.to_markdown(table))
  end

  @doc "Generates a Markdown representation of the section."
  @spec to_markdown(t()) :: String.t()
  def to_markdown(%__MODULE__{content: content}) do
    Enum.join(content, "\n")
  end

  defp append(%__MODULE__{content: content} = section, item) do
    %{section | content: content ++ [item]}
  end

  defimpl String.Chars do
    def to_string(section),
      do: OpenrelikWorkerCommon.Reporting.MarkdownDocumentSection.to_markdown(section)
  end
end

defmodule OpenrelikWorkerCommon.Reporting.MarkdownDocument do
  @moduledoc """
  Represents a Markdown document (`openrelik_worker_common.reporting.MarkdownDocument`).
  """

  alias OpenrelikWorkerCommon.Reporting.MarkdownDocumentSection
  alias OpenrelikWorkerCommon.Reporting.MarkdownFormatter
  alias OpenrelikWorkerCommon.Reporting.Priority

  @type t :: %__MODULE__{
          title: String.t() | nil,
          summary: String.t(),
          priority: Priority.t(),
          sections: [MarkdownDocumentSection.t()],
          fmt: MarkdownFormatter.t()
        }

  defstruct title: nil,
            summary: "",
            priority: Priority.low(),
            sections: [],
            fmt: %MarkdownFormatter{}

  @doc "Initializes a `MarkdownDocument` struct."
  @spec new(String.t() | nil) :: t()
  def new(title \\ nil) do
    %__MODULE__{title: title, sections: [], fmt: %MarkdownFormatter{}}
  end

  @doc """
  Adds a section to the document.

  When called with just `document`, appends an empty `%MarkdownDocumentSection{}` and returns
  `{updated_document, new_section}` or, if passed a `%MarkdownDocumentSection{}` or builder
  function `(section -> section)`, appends the populated section and returns `updated_document`.
  """
  @spec add_section(t()) :: {t(), MarkdownDocumentSection.t()}
  def add_section(%__MODULE__{sections: sections} = doc) do
    section = MarkdownDocumentSection.new()
    {%{doc | sections: sections ++ [section]}, section}
  end

  @spec add_section(
          t(),
          MarkdownDocumentSection.t()
          | (MarkdownDocumentSection.t() -> MarkdownDocumentSection.t())
        ) :: t()
  def add_section(%__MODULE__{sections: sections} = doc, %MarkdownDocumentSection{} = section) do
    %{doc | sections: sections ++ [section]}
  end

  def add_section(%__MODULE__{sections: sections} = doc, fun) when is_function(fun, 1) do
    section = fun.(MarkdownDocumentSection.new())
    %{doc | sections: sections ++ [section]}
  end

  @doc "Generates a Markdown representation of the document."
  @spec to_markdown(t()) :: String.t()
  def to_markdown(%__MODULE__{title: title, sections: sections}) do
    header =
      if is_binary(title) and title != "" do
        "#{MarkdownFormatter.title(title)}\n"
      else
        ""
      end

    sections_md =
      Enum.map_join(sections, "", fn section ->
        "\n#{MarkdownDocumentSection.to_markdown(section)}"
      end)

    header <> sections_md
  end

  @doc "Generates a dictionary (string-keyed map) representation of the document."
  @spec to_dict(t()) :: %{String.t() => term()}
  def to_dict(%__MODULE__{} = doc) do
    %{
      "title" => doc.title,
      "summary" => doc.summary,
      "content" => to_markdown(doc),
      "priority" => Priority.value(doc.priority)
    }
  end

  @doc "Generates a JSON representation of the document."
  @spec to_json(t()) :: String.t()
  def to_json(%__MODULE__{} = doc) do
    doc |> to_dict() |> JSON.encode!()
  end

  defimpl String.Chars do
    def to_string(doc), do: OpenrelikWorkerCommon.Reporting.MarkdownDocument.to_markdown(doc)
  end
end

defmodule OpenrelikWorkerCommon.Reporting.Report do
  @moduledoc """
  Represents a task report (`openrelik_worker_common.reporting.Report`), inheriting behavior
  from `MarkdownDocument`.
  """

  alias OpenrelikWorkerCommon.Reporting.MarkdownDocument
  alias OpenrelikWorkerCommon.Reporting.MarkdownDocumentSection
  alias OpenrelikWorkerCommon.Reporting.MarkdownFormatter
  alias OpenrelikWorkerCommon.Reporting.Priority

  @type t :: %__MODULE__{
          title: String.t() | nil,
          summary: String.t(),
          priority: Priority.t(),
          sections: [MarkdownDocumentSection.t()],
          fmt: MarkdownFormatter.t()
        }

  defstruct title: nil,
            summary: "",
            priority: Priority.low(),
            sections: [],
            fmt: %MarkdownFormatter{}

  @doc "Initializes a `Report` struct."
  @spec new(String.t() | nil, keyword()) :: t()
  def new(title \\ nil, opts \\ []) do
    %__MODULE__{
      title: title,
      summary: Keyword.get(opts, :summary, ""),
      priority: Keyword.get(opts, :priority, Priority.low()),
      sections: Keyword.get(opts, :sections, []),
      fmt: %MarkdownFormatter{}
    }
  end

  @doc """
  Adds a section to the report.

  Supports:
  - `Report.add_section(report)` -> `{updated_report, section}`
  - `Report.add_section(report, %MarkdownDocumentSection{})` -> `updated_report`
  - `Report.add_section(report, fn section -> ... end)` -> `updated_report`
  """
  @spec add_section(t()) :: {t(), MarkdownDocumentSection.t()}
  def add_section(%__MODULE__{sections: sections} = report) do
    section = MarkdownDocumentSection.new()
    {%{report | sections: sections ++ [section]}, section}
  end

  @spec add_section(
          t(),
          MarkdownDocumentSection.t()
          | (MarkdownDocumentSection.t() -> MarkdownDocumentSection.t())
        ) :: t()
  def add_section(%__MODULE__{sections: sections} = report, %MarkdownDocumentSection{} = section) do
    %{report | sections: sections ++ [section]}
  end

  def add_section(%__MODULE__{sections: sections} = report, fun) when is_function(fun, 1) do
    section = fun.(MarkdownDocumentSection.new())
    %{report | sections: sections ++ [section]}
  end

  @doc "Generates a Markdown representation of the report."
  @spec to_markdown(t()) :: String.t()
  def to_markdown(%__MODULE__{title: title, sections: sections}) do
    MarkdownDocument.to_markdown(%MarkdownDocument{title: title, sections: sections})
  end

  @doc "Generates a dictionary (string-keyed map) representation of the report."
  @spec to_dict(t()) :: %{String.t() => term()}
  def to_dict(%__MODULE__{} = report) do
    %{
      "title" => report.title,
      "summary" => report.summary,
      "content" => to_markdown(report),
      "priority" => Priority.value(report.priority)
    }
  end

  @doc "Generates a JSON representation of the report."
  @spec to_json(t()) :: String.t()
  def to_json(%__MODULE__{} = report) do
    report |> to_dict() |> JSON.encode!()
  end

  defimpl String.Chars do
    def to_string(report), do: OpenrelikWorkerCommon.Reporting.Report.to_markdown(report)
  end
end

defmodule OpenrelikWorkerCommon.Reporting do
  @moduledoc """
  Helper functions and structs for reporting (`openrelik_worker_common.reporting`).
  """

  alias OpenrelikWorkerCommon.FileUtils.OutputFile
  alias OpenrelikWorkerCommon.Reporting.Priority

  @doc """
  Serializes a file report into a dictionary (string-keyed map) for use in a task result.
  """
  @spec serialize_file_report(map(), OutputFile.t() | map(), map()) :: %{String.t() => term()}
  def serialize_file_report(input_file, report_file, report)
      when is_map(input_file) and is_map(report_file) and is_map(report) do
    input_file_uuid =
      Map.get(input_file, "uuid") || Map.get(input_file, :uuid)

    content_file_uuid =
      Map.get(report_file, :uuid) || Map.get(report_file, "uuid")

    summary = Map.get(report, :summary) || Map.get(report, "summary")
    priority = Map.get(report, :priority) || Map.get(report, "priority")

    %{
      "summary" => summary,
      "priority" => if(is_nil(priority), do: nil, else: Priority.value(priority)),
      "input_file_uuid" => input_file_uuid,
      "content_file_uuid" => content_file_uuid
    }
  end
end

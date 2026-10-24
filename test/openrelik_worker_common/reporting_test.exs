defmodule OpenrelikWorkerCommon.ReportingTest do
  use ExUnit.Case, async: true

  alias OpenrelikWorkerCommon.FileUtils
  alias OpenrelikWorkerCommon.Reporting
  alias OpenrelikWorkerCommon.Reporting.MarkdownDocument
  alias OpenrelikWorkerCommon.Reporting.MarkdownDocumentSection
  alias OpenrelikWorkerCommon.Reporting.MarkdownFormatter
  alias OpenrelikWorkerCommon.Reporting.MarkdownTable
  alias OpenrelikWorkerCommon.Reporting.Priority
  alias OpenrelikWorkerCommon.Reporting.Report

  test "markdown_document_init" do
    document = MarkdownDocument.new("Test Document")
    assert document.title == "Test Document"
    assert document.sections == []
  end

  test "markdown_document_add" do
    report =
      Report.new("Test Report",
        summary: "Test Summary",
        priority: Priority.low()
      )

    document = MarkdownDocument.new("Test Title")

    section =
      MarkdownDocumentSection.new()
      |> MarkdownDocumentSection.add_header("Test Header", level: 2)
      |> MarkdownDocumentSection.add_bullet("Test Bullet", level: 1)
      |> MarkdownDocumentSection.add_code("Test Code")
      |> MarkdownDocumentSection.add_code_block("Test Code Block")
      |> MarkdownDocumentSection.add_blockquote("Test Blockquote")
      |> MarkdownDocumentSection.add_paragraph(MarkdownFormatter.bold("Test Paragraph"))
      |> MarkdownDocumentSection.add_horizontal_rule()

    table =
      MarkdownTable.new(["column1", "column2"])
      |> MarkdownTable.add_row(["row1", "row2"])

    section = MarkdownDocumentSection.add_table(section, table)
    document = MarkdownDocument.add_section(document, section)

    assert_raise ArgumentError,
                 "Number of columns in row data does not match table columns.",
                 fn ->
                   MarkdownTable.add_row(table, ["row1", "row2", "rowthatshouldnotbehere"])
                 end

    assert_raise ArgumentError, "Heading level must be between 1 and 5", fn ->
      MarkdownFormatter.heading("Test Header", 999)
    end

    markdown = MarkdownDocument.to_markdown(document)
    assert %MarkdownDocumentSection{} = section
    assert markdown =~ "# Test Title"
    assert markdown =~ "## Test Header"
    assert markdown =~ "* Test Bullet"
    assert markdown =~ "`Test Code`"
    assert markdown =~ "```\nTest Code Block\n```"
    assert markdown =~ "> Test Blockquote"
    assert markdown =~ "**Test Paragraph**"
    assert markdown =~ "---"
    assert markdown =~ "|column1|column2|"

    decoded_json = report |> Report.to_json() |> JSON.decode!()

    assert decoded_json == %{
             "title" => "Test Report",
             "summary" => "Test Summary",
             "content" => "# Test Report\n",
             "priority" => 10
           }
  end

  test "markdown_document_to_markdown" do
    document = MarkdownDocument.new("Test Document")
    markdown = MarkdownDocument.to_markdown(document)
    assert markdown =~ "# Test Document"
  end

  test "markdown_report_to_markdown" do
    document = Report.new("Test Report")
    markdown = Report.to_markdown(document)
    assert markdown =~ "# Test Report"
  end

  test "markdown_report_without_title" do
    document = Report.new()
    markdown = Report.to_markdown(document)
    assert markdown == ""
  end

  test "markdown_document_section_init" do
    section = MarkdownDocumentSection.new()
    assert section.content == []
  end

  test "serialize_file_report" do
    input_file = %{"uuid" => "input-uuid-123"}
    report_file = FileUtils.create_output_file("/tmp", uuid: "report-uuid-456")

    report = %Report{
      Report.new("File Report")
      | summary: "Found 3 items",
        priority: Priority.high()
    }

    serialized = Reporting.serialize_file_report(input_file, report_file, report)

    assert serialized == %{
             "summary" => "Found 3 items",
             "priority" => 40,
             "input_file_uuid" => "input-uuid-123",
             "content_file_uuid" => "report-uuid-456"
           }
  end
end

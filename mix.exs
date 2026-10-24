defmodule OpenrelikWorkerCommon.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/hacktobeer/openrelik-worker-common-elixir"

  def project do
    [
      app: :openrelik_worker_common,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      docs: docs()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:redix, "~> 1.5"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp description do
    """
    Elixir port of Python's openrelik-worker-common library — shared helpers for
    OpenRelik workers including task input/output serialization, file handling,
    archive extraction, disk image mounting, password hash bruteforcing, and
    Markdown reporting.
    """
  end

  defp package do
    [
      name: "openrelik_worker_common",
      maintainers: ["hacktobeer"],
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => @source_url,
        "Original Python Library" => "https://github.com/openrelik/openrelik-worker-common"
      },
      files: ~w(lib .formatter.exs mix.exs README.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_url: @source_url,
      source_ref: "v#{@version}",
      extras: ["README.md", "LICENSE"],
      groups_for_modules: [
        Core: [
          OpenrelikWorkerCommon,
          OpenrelikWorkerCommon.DataTypes,
          OpenrelikWorkerCommon.DataTypes.DataType
        ],
        "Tasks & Files": [
          OpenrelikWorkerCommon.TaskUtils,
          OpenrelikWorkerCommon.FileUtils,
          OpenrelikWorkerCommon.FileUtils.OutputFile,
          OpenrelikWorkerCommon.FileUtils.TemporaryDirectory
        ],
        Reporting: [
          OpenrelikWorkerCommon.Reporting,
          OpenrelikWorkerCommon.Reporting.Report,
          OpenrelikWorkerCommon.Reporting.MarkdownDocument,
          OpenrelikWorkerCommon.Reporting.MarkdownDocumentSection,
          OpenrelikWorkerCommon.Reporting.MarkdownTable,
          OpenrelikWorkerCommon.Reporting.MarkdownFormatter,
          OpenrelikWorkerCommon.Reporting.Priority
        ],
        "Archives, Mounting & Passwords": [
          OpenrelikWorkerCommon.ArchiveUtils,
          OpenrelikWorkerCommon.MountUtils,
          OpenrelikWorkerCommon.MountUtils.BlockDevice,
          OpenrelikWorkerCommon.MountUtils.RedisLock,
          OpenrelikWorkerCommon.PasswordUtils
        ]
      ]
    ]
  end
end

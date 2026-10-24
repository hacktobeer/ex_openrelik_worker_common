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

defmodule OpenrelikWorkerCommon.DataTypes.DataType do
  @moduledoc """
  OpenRelik data types (`StrEnum` equivalent).

  Defines standard OpenRelik data types that can be used for input and output files,
  supporting both constant/atom access and direct string/glob comparison.
  """

  @diskimage_qcow "diskimage:qcow"
  @diskimage_raw "diskimage:raw"
  @binary "binary"

  @type t :: String.t()

  @doc "Returns `\"diskimage:qcow\"`."
  @spec diskimage_qcow() :: String.t()
  def diskimage_qcow, do: @diskimage_qcow

  @doc "Returns `\"diskimage:raw\"`."
  @spec diskimage_raw() :: String.t()
  def diskimage_raw, do: @diskimage_raw

  @doc "Returns `\"binary\"`."
  @spec binary() :: String.t()
  def binary, do: @binary

  @doc "Returns all defined `DataType` string values."
  @spec values() :: [String.t()]
  def values, do: [@diskimage_qcow, @diskimage_raw, @binary]

  @doc "Returns whether `value` is a known `DataType`."
  @spec valid?(term()) :: boolean()
  def valid?(value) when is_binary(value), do: value in [@diskimage_qcow, @diskimage_raw, @binary]

  def valid?(value) when is_atom(value),
    do:
      value in [
        :DISKIMAGE_QCOW,
        :DISKIMAGE_RAW,
        :BINARY,
        :diskimage_qcow,
        :diskimage_raw,
        :binary
      ]

  def valid?(_), do: false

  @doc "Converts an atom or string data type identifier into its canonical string value."
  @spec to_string(atom() | String.t()) :: String.t()
  def to_string(:DISKIMAGE_QCOW), do: @diskimage_qcow
  def to_string(:diskimage_qcow), do: @diskimage_qcow
  def to_string(:DISKIMAGE_RAW), do: @diskimage_raw
  def to_string(:diskimage_raw), do: @diskimage_raw
  def to_string(:BINARY), do: @binary
  def to_string(:binary), do: @binary
  def to_string(value) when is_binary(value), do: value
end

defmodule OpenrelikWorkerCommon.DataTypes do
  @moduledoc """
  OpenRelik data types (`openrelik_worker_common.data_types`).

  Defines the OpenRelik data types that can be used for input and output files.
  """

  alias OpenrelikWorkerCommon.DataTypes.DataType

  defdelegate diskimage_qcow(), to: DataType
  defdelegate diskimage_raw(), to: DataType
  defdelegate binary(), to: DataType
  defdelegate values(), to: DataType
  defdelegate valid?(value), to: DataType
end

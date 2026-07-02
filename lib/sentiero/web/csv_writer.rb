# frozen_string_literal: true

module Sentiero
  module Web
    # Minimal RFC 4180 CSV serializer with spreadsheet-formula-injection guarding:
    # cells starting with a formula trigger are prefixed with a single quote so the
    # spreadsheet treats them as text rather than executing them.
    module CsvWriter
      # Tab/CR included: some spreadsheets strip them before re-evaluating the cell.
      FORMULA_TRIGGERS = ["=", "+", "-", "@", "\t", "\r"].freeze

      module_function

      def generate(headers, rows)
        ([headers] + rows).map { |row| format_row(row) }.join("\r\n") + "\r\n"
      end

      def format_row(row)
        row.map { |cell| format_cell(cell) }.join(",")
      end

      def format_cell(cell)
        quote(guard_injection(stringify(cell)))
      end

      def stringify(cell)
        case cell
        when nil then ""
        when true then "true"
        when false then "false"
        else cell.to_s
        end
      end

      def guard_injection(value)
        value.start_with?(*FORMULA_TRIGGERS) ? "'#{value}" : value
      end

      def quote(value)
        return value unless value.match?(/[",\r\n]/)
        %("#{value.gsub('"', '""')}")
      end
    end
  end
end

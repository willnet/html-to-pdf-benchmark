require "timeout"
require "open3"
require_relative "base"

module Engines
  class Wkhtmltopdf < Base
    def name
      "wkhtmltopdf"
    end

    def render(html_path:, output_path:)
      html = File.read(html_path)
      status = nil

      Timeout.timeout(timeout_sec) do
        _stdout, _stderr, status = Open3.capture3(
          command_path,
          "--quiet",
          "--enable-local-file-access",
          "-",
          output_path,
          stdin_data: html
        )
      end

      raise "wkhtmltopdf command failed" unless status&.success?
    end

    private

    def command_path
      return ENV.fetch("WKHTMLTOPDF_BIN") if ENV["WKHTMLTOPDF_BIN"] && !ENV["WKHTMLTOPDF_BIN"].empty?

      "/usr/bin/wkhtmltopdf"
    end
  end
end

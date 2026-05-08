require "grover"
require_relative "base"

module Engines
  class GroverEngine < Base
    def name
      "grover"
    end

    def render(html_path:, output_path:)
      html = File.read(html_path)
      options = {
        format: "A4",
        print_background: true,
        display_url: display_url(html_path),
        wait_until: "networkidle0",
        launch_args: chrome_launch_args
      }
      options[:executable_path] = ENV.fetch("CHROME_BIN") if ENV["CHROME_BIN"] && !ENV["CHROME_BIN"].empty?

      pdf = ::Grover.new(html, **options).to_pdf
      File.binwrite(output_path, pdf)
    end

    private

    def display_url(path)
      "http://example.com/#{File.basename(path)}"
    end

    def chrome_launch_args
      ["--no-sandbox", "--disable-setuid-sandbox", "--disable-dev-shm-usage", "--disable-gpu"]
    end
  end
end

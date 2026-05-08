require "ferrum"
require_relative "base"

module Engines
  class FerrumPdf < Base
    @@browser = nil
    @@browser_mutex = Mutex.new

    def name
      "ferrum_pdf"
    end

    def supports_warm?
      true
    end

    def boot
      with_browser { }
    end

    def shutdown
      @@browser_mutex.synchronize do
        @@browser&.quit
        @@browser = nil
      end
    end

    def render(html_path:, output_path:)
      html = File.read(html_path)
      with_browser do |browser|
        page = browser.create_page
        page.content = html
        page.pdf(path: output_path, format: :A4, print_background: true)
      ensure
        page&.close
      end
    end

    private

    def with_browser
      @@browser_mutex.synchronize do
        @@browser ||= Ferrum::Browser.new(browser_options)
        yield @@browser
      end
    end

    def browser_options
      options = {
        timeout: timeout_sec,
        browser_options: {
          "no-sandbox": nil,
          "disable-setuid-sandbox": nil,
          "disable-dev-shm-usage": nil,
          "disable-gpu": nil
        }
      }
      options[:browser_path] = ENV.fetch("CHROME_BIN") if ENV["CHROME_BIN"] && !ENV["CHROME_BIN"].empty?
      options
    end

  end
end

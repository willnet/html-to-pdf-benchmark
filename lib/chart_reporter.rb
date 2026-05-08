require "csv"
require "fileutils"
require "json"
require "optparse"
require "time"

class ChartReporter
  GROUP_KEYS = %i[engine mode case_name concurrency threads].freeze

  def initialize(argv)
    @argv = argv
    @root_dir = File.expand_path("..", __dir__)
  end

  def run
    options = parse_options
    input_paths = resolve_input_paths(options)
    rows = read_rows(input_paths)
    raise "No rows found in #{input_paths.join(', ')}" if rows.empty?

    FileUtils.mkdir_p(charts_dir)
    output_path = options[:output] || default_output_path(input_paths, options)
    File.write(output_path, render_html(input_paths, rows, show_rss: options[:show_rss]))

    puts "Chart report: #{output_path}"
  end

  private

  def parse_options
    options = {}

    OptionParser.new do |parser|
      parser.banner = "Usage: bundle exec ruby bin/generate_chart_report [CSV_PATH ...] [options]"
      parser.on("--latest") { options[:latest] = true }
      parser.on("--all") { options[:all] = true }
      parser.on("--output PATH") { |value| options[:output] = File.expand_path(value, Dir.pwd) }
      parser.on("--show-rss") { options[:show_rss] = true }
    end.parse!(@argv)

    options[:inputs] = @argv.dup
    options
  end

  def resolve_input_paths(options)
    selected_modes = [options[:all], options[:latest], !options[:inputs].empty?].count(true)
    raise "Use only one of CSV paths, --latest, or --all" if selected_modes > 1

    paths = if options[:all]
      all_csvs
    elsif options[:latest]
      [latest_csv]
    elsif !options[:inputs].empty?
      options[:inputs].map { |input| File.expand_path(input, Dir.pwd) }
    end

    raise "Specify CSV path(s), --latest, or --all" if paths.nil? || paths.empty?

    paths.each do |path|
      raise "CSV not found: #{path}" unless File.file?(path)
    end

    paths
  end

  def all_csvs
    paths = Dir[File.join(@root_dir, "results", "raw", "*.csv")].sort
    raise "No CSV files found in results/raw" if paths.empty?

    paths
  end

  def latest_csv
    path = Dir[File.join(@root_dir, "results", "raw", "*.csv")].max_by { |candidate| File.mtime(candidate) }
    raise "No CSV files found in results/raw" unless path

    path
  end

  def read_rows(input_paths)
    input_paths.flat_map do |input_path|
      CSV.read(input_path, headers: true).map do |row|
        {
          source_file: File.basename(input_path),
          run_id: row["run_id"],
          engine: row["engine"],
          mode: row["mode"],
          case_name: row["case_name"],
          concurrency: integer(row["concurrency"]),
          threads: integer(row["threads"], default: 1),
          iteration: integer(row["iteration"]),
          status: row["status"],
          duration_ms: number(row["duration_ms"]),
          max_rss_kb: number(row["max_rss_kb"]),
          max_pss_kb: number(row["max_pss_kb"]),
          avg_cpu_percent: number(row["avg_cpu_percent"]),
          max_cpu_percent: number(row["max_cpu_percent"]),
          process_count_max: integer(row["process_count_max"]),
          pdf_bytes: number(row["pdf_bytes"]),
          worker_index: integer(row["worker_index"]),
          thread_index: integer(row["thread_index"]),
          error: row["error"]
        }
      end
    end
  end

  def render_html(input_paths, rows, show_rss: false)
    summaries = grouped_summaries(rows)
    payload = {
      input_paths: input_paths,
      generated_at: Time.now.iso8601,
      show_rss: show_rss,
      summaries: summaries,
      rows: rows
    }
    memory_title = show_rss ? "Max RSS / PSS (MB)" : "Max PSS (MB)"

    <<~HTML
      <!DOCTYPE html>
      <html lang="ja">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>HTML to PDF Benchmark Chart</title>
          <script src="https://cdn.jsdelivr.net/npm/chart.js"></script>
          <style>
            :root {
              color-scheme: light;
              --bg: #f8fafc;
              --panel: #ffffff;
              --text: #0f172a;
              --muted: #64748b;
              --border: #e2e8f0;
              --accent: #2563eb;
            }

            body {
              margin: 0;
              background: var(--bg);
              color: var(--text);
              font-family: ui-sans-serif, system-ui, "Segoe UI", sans-serif;
            }

            header {
              padding: 32px clamp(16px, 4vw, 48px) 20px;
              background: linear-gradient(135deg, #0f172a, #1e3a8a);
              color: #ffffff;
            }

            h1 {
              margin: 0 0 8px;
              font-size: clamp(28px, 4vw, 44px);
              letter-spacing: -0.04em;
            }

            main {
              padding: 24px clamp(16px, 4vw, 48px) 48px;
            }

            .meta {
              margin: 0;
              color: #bfdbfe;
              overflow-wrap: anywhere;
            }

            .sources {
              margin: 12px 0 0;
              padding-left: 18px;
              color: #dbeafe;
              font-size: 13px;
            }

            .sources li {
              margin: 2px 0;
              overflow-wrap: anywhere;
            }

            .notice {
              margin: 0 0 20px;
              padding: 12px 14px;
              border: 1px solid #bfdbfe;
              border-radius: 12px;
              background: #eff6ff;
              color: #1e3a8a;
            }

            .grid {
              display: grid;
              grid-template-columns: repeat(2, minmax(0, 1fr));
              gap: 20px;
            }

            .panel {
              background: var(--panel);
              border: 1px solid var(--border);
              border-radius: 16px;
              padding: 18px;
              box-shadow: 0 12px 30px rgba(15, 23, 42, 0.06);
            }

            .wide {
              grid-column: 1 / -1;
            }

            h2 {
              margin: 0 0 14px;
              font-size: 18px;
            }

            .chart-box {
              position: relative;
              height: 320px;
              max-height: 45vh;
            }

            .chart-box.compact {
              height: 260px;
            }

            canvas {
              display: block;
              width: 100% !important;
              height: 100% !important;
            }

            table {
              width: 100%;
              border-collapse: collapse;
              font-size: 13px;
            }

            th, td {
              padding: 8px 10px;
              border-bottom: 1px solid var(--border);
              text-align: right;
              white-space: nowrap;
            }

            th:first-child, td:first-child {
              text-align: left;
            }

            th {
              color: var(--muted);
              font-weight: 700;
            }

            .table-wrap {
              overflow-x: auto;
            }

            .ok { color: #15803d; }
            .error { color: #b91c1c; }

            @media (max-width: 900px) {
              .grid { grid-template-columns: 1fr; }
              .chart-box { height: 280px; max-height: none; }
              .chart-box.compact { height: 240px; }
            }
          </style>
        </head>
        <body>
          <header>
            <h1>HTML to PDF Benchmark Chart</h1>
            <p class="meta">Inputs: #{input_paths.length} CSV file(s) / Generated: #{escape_html(payload[:generated_at])}</p>
            <ul class="sources">
              #{input_paths.map { |path| "<li>#{escape_html(path)}</li>" }.join("\n")}
            </ul>
          </header>
          <main>
            <p class="notice">Throughput is estimated from each iteration duration in the CSV as <code>concurrency * threads * 1000 / avg_duration_ms</code>. It is not the exact throughput for the entire scenario.</p>
            <section class="grid">
              <article class="panel"><h2>Duration avg / p95 (ms)</h2><div class="chart-box"><canvas id="durationChart"></canvas></div></article>
              <article class="panel"><h2>#{memory_title}</h2><div class="chart-box"><canvas id="memoryChart"></canvas></div></article>
              <article class="panel"><h2>CPU avg / max (%)</h2><div class="chart-box"><canvas id="cpuChart"></canvas></div></article>
              <article class="panel"><h2>Estimated throughput (jobs/sec)</h2><div class="chart-box"><canvas id="throughputChart"></canvas></div></article>
              <article class="panel wide"><h2>Success / Error</h2><div class="chart-box compact"><canvas id="statusChart"></canvas></div></article>
              <article class="panel wide">
                <h2>Summary Table</h2>
                <div class="table-wrap" id="summaryTable"></div>
              </article>
            </section>
          </main>
          <script>
            const payload = #{JSON.pretty_generate(payload)};
            const summaries = payload.summaries;
            const labels = summaries.map((row) => row.label);
            const colors = ["#2563eb", "#16a34a", "#ea580c", "#9333ea", "#0891b2", "#be123c", "#4f46e5", "#65a30d"];

            function dataset(label, key, colorIndex) {
              return {
                label,
                data: summaries.map((row) => row[key]),
                borderColor: colors[colorIndex % colors.length],
                backgroundColor: colors[colorIndex % colors.length] + "33",
                borderWidth: 2
              };
            }

            function barChart(id, datasets) {
              new Chart(document.getElementById(id), {
                type: "bar",
                data: { labels, datasets },
                options: {
                  responsive: true,
                  maintainAspectRatio: false,
                  scales: { x: { ticks: { autoSkip: false, maxRotation: 60, minRotation: 25 } }, y: { beginAtZero: true } },
                  plugins: { legend: { position: "bottom" } }
                }
              });
            }

            barChart("durationChart", [dataset("avg", "duration_avg", 0), dataset("p95", "duration_p95", 1)]);
            const memoryDatasets = payload.show_rss ? [dataset("max rss", "rss_mb_max", 2), dataset("max pss", "pss_mb_max", 6)] : [dataset("max pss", "pss_mb_max", 6)];
            barChart("memoryChart", memoryDatasets);
            barChart("cpuChart", [dataset("avg cpu", "cpu_avg", 3), dataset("max cpu", "cpu_max", 4)]);
            barChart("throughputChart", [dataset("estimated throughput", "estimated_throughput", 5)]);
            barChart("statusChart", [dataset("success", "success_count", 1), dataset("error", "error_count", 5)]);

            document.getElementById("summaryTable").innerHTML = `
              <table>
                <thead>
                  <tr>
                    <th>scenario</th><th>n</th><th>success</th><th>error</th><th>avg ms</th><th>p95 ms</th>${payload.show_rss ? "<th>max rss MB</th>" : ""}<th>max pss MB</th><th>avg CPU %</th><th>max CPU %</th><th>PDF avg KB</th><th>throughput</th>
                  </tr>
                </thead>
                <tbody>
                  ${summaries.map((row) => `
                    <tr>
                      <td>${row.label}</td>
                      <td>${row.n}</td>
                      <td class="ok">${row.success_count}</td>
                      <td class="error">${row.error_count}</td>
                      <td>${row.duration_avg.toFixed(1)}</td>
                      <td>${row.duration_p95.toFixed(1)}</td>
                      ${payload.show_rss ? `<td>${row.rss_mb_max.toFixed(1)}</td>` : ""}
                      <td>${row.pss_mb_max.toFixed(1)}</td>
                      <td>${row.cpu_avg.toFixed(1)}</td>
                      <td>${row.cpu_max.toFixed(1)}</td>
                      <td>${row.pdf_kb_avg.toFixed(1)}</td>
                      <td>${row.estimated_throughput.toFixed(2)}</td>
                    </tr>
                  `).join("")}
                </tbody>
              </table>
            `;
          </script>
        </body>
      </html>
    HTML
  end

  def grouped_summaries(rows)
    rows.group_by { |row| GROUP_KEYS.map { |key| row[key] } }
      .sort_by { |key, _| key }
      .map do |key, group_rows|
        ok_rows = group_rows.select { |row| row[:status] == "ok" }
        durations = ok_rows.map { |row| row[:duration_ms] }
        duration_avg = average(durations)
        concurrency = key[3].to_i
        threads = key[4].to_i

        {
          label: label_for(key),
          engine: key[0],
          mode: key[1],
          case_name: key[2],
          concurrency: concurrency,
          threads: threads,
          n: group_rows.length,
          success_count: ok_rows.length,
          error_count: group_rows.length - ok_rows.length,
          duration_avg: duration_avg.round(1),
          duration_p95: percentile(durations, 0.95).round(1),
          duration_max: (durations.max || 0.0).round(1),
          rss_mb_max: ((group_rows.map { |row| row[:max_rss_kb] }.max || 0.0) / 1024.0).round(1),
          pss_mb_max: ((group_rows.map { |row| row[:max_pss_kb] }.max || 0.0) / 1024.0).round(1),
          cpu_avg: average(group_rows.map { |row| row[:avg_cpu_percent] }).round(1),
          cpu_max: (group_rows.map { |row| row[:max_cpu_percent] }.max || 0.0).round(1),
          pdf_kb_avg: (average(ok_rows.map { |row| row[:pdf_bytes] }) / 1024.0).round(1),
          estimated_throughput: duration_avg.positive? ? (concurrency * threads * 1000.0 / duration_avg).round(2) : 0.0
        }
      end
  end

  def label_for(key)
    engine, _mode, case_name, concurrency, threads = key
    "#{engine} / #{case_name} / p#{concurrency} x t#{threads}"
  end

  def average(values)
    return 0.0 if values.empty?

    values.sum.to_f / values.length
  end

  def percentile(values, ratio)
    return 0.0 if values.empty?

    sorted = values.sort
    index = [(sorted.length * ratio).ceil - 1, 0].max
    sorted[index]
  end

  def number(value)
    value.to_s.empty? ? 0.0 : value.to_f
  end

  def integer(value, default: 0)
    value.to_s.empty? ? default : value.to_i
  end

  def escape_html(value)
    value.to_s
      .gsub("&", "&amp;")
      .gsub("<", "&lt;")
      .gsub(">", "&gt;")
      .gsub('"', "&quot;")
  end

  def default_output_path(input_paths, options)
    basename = if options[:all]
      "all-results"
    elsif input_paths.length == 1
      File.basename(input_paths.first, ".csv")
    else
      "combined-#{Time.now.strftime('%Y%m%d-%H%M%S')}"
    end

    File.join(charts_dir, "#{basename}.html")
  end

  def charts_dir
    File.join(@root_dir, "results", "charts")
  end
end

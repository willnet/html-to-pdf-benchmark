require "csv"
require "fileutils"

class ResultRecorder
  HEADERS = %w[
    run_id engine mode case_name concurrency threads iteration status duration_ms max_rss_kb max_pss_kb
    avg_cpu_percent max_cpu_percent process_count_max pdf_bytes worker_index thread_index error
  ].freeze

  def initialize(output_root:, run_id:, show_rss: false)
    @output_root = output_root
    @run_id = run_id
    @show_rss = show_rss
    FileUtils.mkdir_p(raw_dir)
    FileUtils.mkdir_p(summary_dir)
  end

  def write(results:, scenario_stats:)
    write_csv(results)
    write_summary(results, scenario_stats)
  end

  private

  def write_csv(results)
    CSV.open(csv_path, csv_mode, write_headers: csv_new?, headers: HEADERS) do |csv|
      results.each do |row|
        csv << HEADERS.map { |header| row[header.to_sym] }
      end
    end
  end

  def write_summary(results, scenario_stats)
    File.write(summary_path, summary_markdown(results, scenario_stats))
  end

  def summary_markdown(results, scenario_stats)
    lines = []
    lines << "# Benchmark Summary"
    lines << ""
    lines << "Run ID: `#{@run_id}`"
    lines << ""
    headers = ["engine", "mode", "case", "concurrency", "threads", "n", "success", "avg ms", "p95 ms"]
    headers << "max rss MB" if @show_rss
    headers.concat(["max pss MB", "avg cpu %", "throughput jobs/s"])
    alignments = ["---", "---", "---", "---:", "---:", "---:", "---:", "---:", "---:"]
    alignments << "---:" if @show_rss
    alignments.concat(["---:", "---:", "---:"])
    lines << markdown_row(headers)
    lines << markdown_row(alignments)

    grouped_results(results).each do |key, rows|
      stat = scenario_stats.fetch(key)
      durations = rows.select { |row| row[:status] == "ok" }.map { |row| row[:duration_ms] }
      rss_mb = (rows.map { |row| row[:max_rss_kb] }.max || 0) / 1024.0
      pss_mb = (rows.map { |row| row[:max_pss_kb] }.max || 0) / 1024.0
      success = rows.count { |row| row[:status] == "ok" }
      values = [
        key[0], key[1], key[2], key[3], key[4], rows.length, success,
        format("%.1f", average(durations)),
        format("%.1f", percentile(durations, 0.95))
      ]
      values << format("%.1f", rss_mb) if @show_rss
      values.concat([
        format("%.1f", pss_mb),
        format("%.1f", average(rows.map { |row| row[:avg_cpu_percent] })),
        format("%.2f", stat[:throughput_jobs_per_sec])
      ])
      lines << markdown_row(values)
    end

    lines.join("\n")
  end

  def grouped_results(results)
    results.group_by { |row| [row[:engine], row[:mode], row[:case_name], row[:concurrency], row[:threads] || 1] }
      .sort_by { |key, _| key }
  end

  def markdown_row(values)
    values.join(" | ").prepend("| ").concat(" |")
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

  def csv_path
    File.join(raw_dir, "#{@run_id}.csv")
  end

  def summary_path
    File.join(summary_dir, "#{@run_id}.md")
  end

  def raw_dir
    File.join(@output_root, "raw")
  end

  def summary_dir
    File.join(@output_root, "summary")
  end

  def csv_mode
    csv_new? ? "wb" : "ab"
  end

  def csv_new?
    !File.exist?(csv_path)
  end
end

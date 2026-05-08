require "fileutils"
require "json"
require "optparse"
require "thread"
require "time"
require "timeout"
require "yaml"

require_relative "process_sampler"
require_relative "result_recorder"

class BenchmarkRunner
  ENGINE_MAP = {
    "wkhtmltopdf" => { require_path: "engines/wkhtmltopdf", class_name: "Engines::Wkhtmltopdf" },
    "grover" => { require_path: "engines/grover", class_name: "Engines::GroverEngine" },
    "ferrum_pdf" => { require_path: "engines/ferrum_pdf", class_name: "Engines::FerrumPdf" }
  }.freeze

  Scenario = Struct.new(:engine_name, :case_name, :mode, :concurrency, :threads, :iterations, keyword_init: true)

  def initialize(argv)
    @argv = argv
    @root_dir = File.expand_path("..", __dir__)
    @run_id = "#{Time.now.strftime('%Y%m%d-%H%M%S-%6N')}-#{Process.pid}"
  end

  def run
    options = parse_options
    config = load_config(options[:config])
    setup_output_paths(config)

    recorder = ResultRecorder.new(output_root: results_dir, run_id: @run_id, show_rss: options[:show_rss])
    results = []
    scenario_stats = {}

    scenarios(config, options).each do |scenario|
      next if skip_scenario?(scenario)

      puts "Running #{scenario.engine_name} case=#{scenario.case_name} mode=#{scenario.mode} concurrency=#{scenario.concurrency} threads=#{scenario.threads} iterations=#{scenario.iterations}"
      scenario_results, stat = run_scenario(scenario, config)
      results.concat(scenario_results)
      scenario_stats[[scenario.engine_name, scenario.mode, scenario.case_name, scenario.concurrency, scenario.threads]] = stat
    end

    recorder.write(results: results, scenario_stats: scenario_stats)
    csv_path = File.join(results_dir, "raw", "#{@run_id}.csv")
    summary_path = File.join(results_dir, "summary", "#{@run_id}.md")
    puts "CSV: #{csv_path}" if results.any?
    puts "Summary: #{summary_path}" if results.any?
    puts "PDF: #{@pdf_dir}" if results.any?

    { run_id: @run_id, csv_path: csv_path, summary_path: summary_path, results_count: results.length }
  end

  private

  def parse_options
    options = { config: File.join(@root_dir, "config", "benchmark.yml") }

    OptionParser.new do |parser|
      parser.on("--config PATH") { |value| options[:config] = expand_path(value) }
      parser.on("--engine NAME") { |value| options[:engine] = value }
      parser.on("--case NAME") { |value| options[:case_name] = value }
      parser.on("--all-cases") { options[:all_cases] = true }
      parser.on("--mode NAME") { |value| options[:mode] = value }
      parser.on("--concurrency N", Integer) { |value| options[:concurrency] = value }
      parser.on("--threads N", Integer) { |value| options[:threads] = value }
      parser.on("--iterations N", Integer) { |value| options[:iterations] = value }
      parser.on("--show-rss") { options[:show_rss] = true }
    end.parse!(@argv)

    options
  end

  def load_config(path)
    YAML.load_file(path)
  end

  def setup_output_paths(config)
    @results_dir = File.join(@root_dir, config.fetch("output_dir", "results"))
    @pdf_dir = File.join(pdf_output_root, @run_id)
    @metrics_dir = File.join(@root_dir, "tmp", "metrics", @run_id)

    [@results_dir, @pdf_dir, @metrics_dir].each { |path| FileUtils.mkdir_p(path) }
  end

  def pdf_output_root
    path = ENV.fetch("PDF_OUTPUT_DIR", File.join(@root_dir, "tmp", "pdf"))
    File.expand_path(path, @root_dir)
  end

  def scenarios(config, options)
    engines = Array(options[:engine] || config.fetch("engines"))
    cases = Array(selected_cases(config, options))
    modes = Array(options[:mode] || config.fetch("modes"))
    concurrencies = Array(options[:concurrency] || config.fetch("concurrency"))
    thread_counts = Array(options[:threads] || config.fetch("threads", 1))
    iterations = Integer(options[:iterations] || config.fetch("iterations"))

    engines.product(cases, concurrencies, thread_counts).flat_map do |engine_name, case_name, concurrency, threads|
      scenario_modes(engine_name, modes).map do |mode|
        Scenario.new(
          engine_name: engine_name,
          case_name: case_name,
          mode: mode,
          concurrency: positive_integer(concurrency, "concurrency"),
          threads: positive_integer(threads, "threads"),
          iterations: iterations
        )
      end
    end
  end

  def scenario_modes(engine_name, modes)
    engine_name == "ferrum_pdf" ? ["warm"] : modes
  end

  def selected_cases(config, options)
    return options[:case_name] if options[:case_name]
    return config.fetch("all_cases") if options[:all_cases]

    config.fetch("cases")
  end

  def skip_scenario?(scenario)
    engine = build_engine(scenario.engine_name, timeout_sec: 1)
    warm_requested = scenario.mode == "warm"

    if scenario.engine_name == "ferrum_pdf" && scenario.mode != "warm"
      puts "Skipping ferrum_pdf #{scenario.mode}: ferrum_pdf benchmarks always run warm"
      return true
    end

    if warm_requested && !engine.supports_warm?
      puts "Skipping #{scenario.engine_name} warm: not supported"
      return true
    end

    false
  end

  def run_scenario(scenario, config)
    sampler = ProcessSampler.new(interval_sec: config.fetch("sample_interval_sec"), root_pid: Process.pid, include_root: false)
    workers = []
    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    sampler.measure do
      workers = spawn_workers(scenario, config)
      workers.each { |worker| Process.wait(worker.fetch(:pid)) }
    end
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
    stats = sampler.summary

    results = workers.map { |worker| worker.fetch(:result_path) }.flat_map do |path|
      File.exist?(path) ? JSON.parse(File.read(path), symbolize_names: true) : []
    end.sort_by { |row| row[:iteration] }.map do |row|
      row.merge(max_rss_kb: stats[:max_rss_kb], max_pss_kb: stats[:max_pss_kb])
    end

    [
      results,
      {
        elapsed_sec: elapsed.round(3),
        throughput_jobs_per_sec: (results.length / elapsed.to_f).round(2),
        max_rss_kb: stats[:max_rss_kb],
        max_pss_kb: stats[:max_pss_kb]
      }
    ]
  end

  def spawn_workers(scenario, config)
    assignments(scenario.iterations, scenario.concurrency).each_with_index.map do |job_ids, worker_index|
      result_path = File.join(@metrics_dir, worker_result_name(scenario, worker_index))

      pid = fork do
        run_worker(scenario, config, worker_index, job_ids, result_path)
        exit! 0
      end

      { pid: pid, result_path: result_path }
    end
  end

  def run_worker(scenario, config, worker_index, job_ids, result_path)
    results = Queue.new
    warm_engine = nil

    if scenario.mode == "warm"
      warm_engine = build_engine(scenario.engine_name, timeout_sec: config.fetch("timeout_sec"))
      warm_engine.boot
    end

    worker_threads = assignments_for_jobs(job_ids, scenario.threads).each_with_index.map do |thread_job_ids, thread_index|
      Thread.new do
        run_worker_thread(
          scenario: scenario,
          config: config,
          worker_index: worker_index,
          thread_index: thread_index,
          job_ids: thread_job_ids,
          results: results
        )
      end
    end

    worker_threads.each(&:value)
    File.write(result_path, JSON.pretty_generate(results.size.times.map { results.pop }.sort_by { |row| row[:iteration] }))
  ensure
    warm_engine&.shutdown
  end

  def run_worker_thread(scenario:, config:, worker_index:, thread_index:, job_ids:, results:)
    engine = build_engine(scenario.engine_name, timeout_sec: config.fetch("timeout_sec"))

    job_ids.each do |iteration|
      results << run_iteration(
        engine: engine,
        scenario: scenario,
        worker_index: worker_index,
        thread_index: thread_index,
        iteration: iteration,
        sample_interval_sec: config.fetch("sample_interval_sec")
      )
    end
  ensure
    engine&.shutdown unless scenario.mode == "warm"
  end

  def run_iteration(engine:, scenario:, worker_index:, thread_index:, iteration:, sample_interval_sec:)
    html_path = File.join(@root_dir, "html", "#{scenario.case_name}.html")
    output_path = File.join(@pdf_dir, pdf_name(scenario, worker_index, thread_index, iteration))
    sampler = ProcessSampler.new(interval_sec: sample_interval_sec, root_pid: Process.pid)
    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    status = "ok"
    error = nil
    begin
      sampler.measure do
        if scenario.mode == "cold"
          engine.boot
          engine.render(html_path: html_path, output_path: output_path)
          engine.shutdown
        else
          engine.render(html_path: html_path, output_path: output_path)
        end
      end
    rescue StandardError => e
      status = "error"
      error = "#{e.class}: #{e.message}"
    ensure
      duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round(1)
      stats = sampler.summary
    end

    {
      run_id: @run_id,
      engine: scenario.engine_name,
      mode: scenario.mode,
      case_name: scenario.case_name,
      concurrency: scenario.concurrency,
      threads: scenario.threads,
      iteration: iteration,
      status: status,
      duration_ms: duration_ms,
      max_rss_kb: stats[:max_rss_kb],
      max_pss_kb: stats[:max_pss_kb],
      avg_cpu_percent: stats[:avg_cpu_percent],
      max_cpu_percent: stats[:max_cpu_percent],
      process_count_max: stats[:process_count_max],
      pdf_bytes: File.exist?(output_path) ? File.size(output_path) : 0,
      worker_index: worker_index,
      thread_index: thread_index,
      error: error
    }
  end

  def assignments(iterations, concurrency)
    jobs = (1..iterations).to_a
    assignments_for_jobs(jobs, concurrency)
  end

  def assignments_for_jobs(jobs, concurrency)
    Array.new(concurrency) { [] }.tap do |slots|
      jobs.each_with_index { |job, index| slots[index % concurrency] << job }
    end.reject(&:empty?)
  end

  def build_engine(engine_name, timeout_sec:)
    definition = ENGINE_MAP.fetch(engine_name) do
      raise ArgumentError, "Unknown engine: #{engine_name}"
    end
    require_relative definition.fetch(:require_path)
    engine_class = Object.const_get(definition.fetch(:class_name))

    engine_class.new(timeout_sec: timeout_sec, base_dir: @root_dir)
  end

  attr_reader :results_dir

  def worker_result_name(scenario, worker_index)
    [scenario.engine_name, scenario.case_name, scenario.mode, scenario.concurrency, scenario.threads, worker_index].join("-") + ".json"
  end

  def pdf_name(scenario, worker_index, thread_index, iteration)
    [scenario.engine_name, scenario.case_name, scenario.mode, scenario.concurrency, scenario.threads, worker_index, thread_index, iteration].join("-") + ".pdf"
  end

  def expand_path(path)
    File.expand_path(path, Dir.pwd)
  end

  def positive_integer(value, name)
    integer = Integer(value)
    raise ArgumentError, "#{name} must be positive: #{value}" unless integer.positive?

    integer
  end
end

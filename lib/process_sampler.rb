require "open3"

class ProcessSampler
  Sample = Struct.new(:rss_kb_total, :pss_kb_total, :cpu_percent_total, :process_count, keyword_init: true)

  def initialize(interval_sec:, root_pid: Process.pid, include_root: true)
    @interval_sec = interval_sec
    @root_pid = root_pid
    @include_root = include_root
    @samples = []
    @running = false
  end

  def measure
    start
    yield
  ensure
    stop
  end

  def summary
    rss_values = @samples.map(&:rss_kb_total)
    pss_values = @samples.map(&:pss_kb_total)
    cpu_values = @samples.map(&:cpu_percent_total)
    process_counts = @samples.map(&:process_count)

    {
      sample_count: @samples.length,
      max_rss_kb: rss_values.max || 0,
      max_pss_kb: pss_values.max || 0,
      avg_cpu_percent: average(cpu_values),
      max_cpu_percent: cpu_values.max || 0.0,
      process_count_max: process_counts.max || 0
    }
  end

  private

  def start
    return if @running

    @running = true
    @thread = Thread.new do
      while @running
        @samples << collect_sample
        sleep @interval_sec
      end
    end
  end

  def stop
    return unless @running

    @running = false
    @thread.join
  end

  def collect_sample
    stdout, status = Open3.capture2("ps", "-axo", "pid=,ppid=,rss=,%cpu=,comm=")
    return empty_sample unless status.success?

    rows = stdout.each_line.map do |line|
      pid, ppid, rss, cpu, command = line.strip.split(/\s+/, 5)
      next unless pid && ppid && rss && cpu && command

      {
        pid: pid.to_i,
        ppid: ppid.to_i,
        rss_kb: rss.to_i,
        cpu_percent: cpu.to_f,
        command: command
      }
    end.compact

    pids = descendant_pids(rows, @root_pid)
    relevant = rows.select { |row| pids.include?(row[:pid]) }

    Sample.new(
      rss_kb_total: relevant.sum { |row| row[:rss_kb] },
      pss_kb_total: relevant.sum { |row| pss_kb(row[:pid]) },
      cpu_percent_total: relevant.sum { |row| row[:cpu_percent] },
      process_count: relevant.length
    )
  rescue StandardError
    empty_sample
  end

  def empty_sample
    Sample.new(rss_kb_total: 0, pss_kb_total: 0, cpu_percent_total: 0.0, process_count: 0)
  end

  def pss_kb(pid)
    path = "/proc/#{pid}/smaps_rollup"
    return pss_kb_from(path) if File.readable?(path)

    path = "/proc/#{pid}/smaps"
    return pss_kb_from(path) if File.readable?(path)

    0
  end

  def pss_kb_from(path)
    File.foreach(path).sum do |line|
      line.start_with?("Pss:") ? line.split[1].to_i : 0
    end
  rescue StandardError
    0
  end

  def descendant_pids(rows, root_pid)
    children = Hash.new { |hash, key| hash[key] = [] }
    rows.each { |row| children[row[:ppid]] << row[:pid] }

    seen = []
    queue = [root_pid]

    until queue.empty?
      current = queue.shift
      next if seen.include?(current)

      seen << current
      queue.concat(children[current])
    end

    @include_root ? seen : seen.reject { |pid| pid == root_pid }
  end

  def average(values)
    return 0.0 if values.empty?

    (values.sum.to_f / values.length).round(2)
  end
end

# HTML to PDF benchmark

This is a minimal benchmark for comparing HTML-to-PDF conversion time, memory usage, and CPU usage trends across `wkhtmltopdf`, `Grover`, and `Ferrum`.

## Prerequisites

- Docker
- Docker Compose

Run benchmarks only inside Docker containers. Ruby, Node.js, Chromium, and wkhtmltopdf are pinned in the Docker image.

Because Grover browser reuse is difficult to control cleanly from outside, this implementation compares only `cold` mode for Grover. Ferrum supports `warm` mode.

## Running With Docker

Docker pins Ruby, Node.js, Chromium, and wkhtmltopdf inside the image, and also `COPY`s the benchmark code into the image. To keep only artifacts on the host, `results/` and `tmp/` are mounted into the container. Generated PDFs are saved under `results/pdf/`, so they can be inspected directly from the host.

```sh
docker compose build
docker compose run --rm benchmark
```

To run with specific conditions, pass the normal Ruby command to `docker compose run`.

```sh
docker compose run --rm benchmark \
  bundle exec ruby bin/run_benchmark --engine ferrum_pdf --case heavy --mode warm --concurrency 4 --threads 2 --iterations 8
```

For a lightweight smoke test:

```sh
docker compose run --rm benchmark \
  bundle exec ruby bin/run_benchmark --engine wkhtmltopdf --case light --mode cold --iterations 1
```

Inside the Docker image, the Linux package at `/usr/bin/wkhtmltopdf` is used. Chrome-based engines use `/usr/bin/chromium`.

## Run

Run all scenarios, then generate charts:

```sh
docker compose run --rm benchmark
```

Run with the report generation command explicitly:

```sh
docker compose run --rm benchmark \
  bundle exec ruby bin/run_benchmark_report
```

Run benchmarks only:

```sh
docker compose run --rm benchmark \
  bundle exec ruby bin/run_benchmark
```

Run with specific conditions:

```sh
docker compose run --rm benchmark \
  bundle exec ruby bin/run_benchmark --engine ferrum_pdf --case heavy --mode warm --concurrency 4 --threads 2 --iterations 8
```

Run all HTML case types:

```sh
docker compose run --rm benchmark \
  bundle exec ruby bin/run_benchmark --all-cases
```

## Output

- Raw data: `results/raw/<timestamp>.csv`
- Summary: `results/summary/<timestamp>.md`
- Chart report: `results/charts/<timestamp>.html`
- Generated PDFs: `results/pdf/<timestamp>/...`
- Worker logs: `tmp/metrics/<timestamp>/...`

Main CSV columns:

- `engine`
- `mode`
- `case_name`
- `concurrency`
- `threads`
- `iteration`
- `duration_ms`
- `max_pss_kb`
- `max_rss_kb`
- `avg_cpu_percent`
- `max_cpu_percent`
- `process_count_max`
- `pdf_bytes`
- `worker_index`
- `thread_index`
- `status`

## Charting

Generate an HTML report from a specific CSV:

```sh
docker compose run --rm benchmark \
  bundle exec ruby bin/generate_chart_report results/raw/20260501-xxxx.csv
```

Generate one HTML report from multiple CSV files:

```sh
docker compose run --rm benchmark \
  bundle exec ruby bin/generate_chart_report \
  results/raw/wkhtmltopdf-result.csv \
  results/raw/ferrum_pdf-result.csv \
  results/raw/grover-result.csv \
  --output results/charts/all-engines.html
```

Generate an HTML report from the latest CSV:

```sh
docker compose run --rm benchmark \
  bundle exec ruby bin/generate_chart_report --latest
```

Generate one HTML report from all `results/raw/*.csv` files:

```sh
docker compose run --rm benchmark \
  bundle exec ruby bin/generate_chart_report --all
```

The generated HTML includes the following charts:

- Average and p95 of `duration_ms`
- Maximum `max_pss_kb` converted to MB
- `avg_cpu_percent` and `max_cpu_percent`
- Estimated throughput
- Success and error counts

Estimated throughput is calculated from each iteration duration in the CSV as `concurrency * threads * 1000 / avg_duration_ms`. It is not the exact throughput for the entire scenario.

To display RSS as well, pass `--show-rss` to `bin/run_benchmark` or `bin/generate_chart_report`.

## Notes

- Compare trends by measuring multiple times in the same Docker runtime environment.
- All HTML fixtures are fully local and do not depend on an external network.
- `warm` is for comparisons that avoid paying the browser startup cost every time, and is supported only by Ferrum.

## Current Measurement Conditions

Default settings are managed in `config/benchmark.yml`.

| Item | Value |
|---|---|
| Target engines | `wkhtmltopdf`, `grover`, `ferrum_pdf` |
| HTML case | `medium` |
| Execution modes | `cold`, `warm` |
| Iterations | `10` |
| Process counts | `1`, `4` |
| Thread counts | `1`, `4` |
| Timeout | `60 seconds` |
| Sampling interval | `0.1 seconds` |
| Output destination | `results` |

By default, scenarios are generated from the following Cartesian product:

```text
engines x cases x modes x concurrency x threads
```

The default parallelism settings are the following four patterns:

```text
concurrency=1, threads=1
concurrency=4, threads=1
concurrency=1, threads=4
concurrency=4, threads=4
```

Engines that do not support `warm` mode are skipped.

To measure all HTML cases (`light`, `medium`, `heavy`, `js`), pass `--all-cases`.

| Engine | cold | warm |
|---|---:|---:|
| `wkhtmltopdf` | Run | Skip |
| `grover` | Run | Skip |
| `ferrum_pdf` | Run | Run |

### Definition of cold / warm

| mode | Description |
|---|---|
| `cold` | Start the engine for each PDF generation and terminate it after the PDF is generated |
| `warm` | Start the engine at the beginning of the scenario and reuse it during each iteration where possible |

Currently, only `ferrum_pdf` supports `warm` mode.

### Parallel Execution

`concurrency` is the number of worker processes to fork. `threads` specifies the number of threads per process.

When needed, you can run in parallel by specifying options such as `--concurrency 4 --threads 2`. In this example, up to `4 * 2 = 8` iterations run concurrently.

Process-level parallelism creates worker processes with `fork`. Iterations are distributed to each worker, and inside each worker, `threads` Ruby threads pull iterations from a job queue and execute them.

Example: `iterations: 10`, `concurrency: 2`, `threads: 2`

```text
worker 0: thread 0/1 runs iterations 1, 3, 5, 7, 9
worker 1: thread 0/1 runs iterations 2, 4, 6, 8, 10
```

Each thread has its own engine instance. However, `ferrum_pdf` keeps only one `Ferrum::Browser` per process, and multiple threads in the same worker use a shared browser protected by a mutex. In `warm` mode, the browser started per worker is reused across iterations processed by that worker.

### Measurements

The following values are recorded for each iteration.

| Metric | Description |
|---|---|
| `duration_ms` | Elapsed time from the start of PDF generation to completion |
| `max_pss_kb` | Maximum PSS during scenario execution. When `concurrency` or `threads` is 2 or greater, this is the summed PSS under concurrently running workers |
| `max_rss_kb` | Maximum RSS during scenario execution. This is recorded in the CSV, but displayed in summaries and charts only when `--show-rss` is specified |
| `avg_cpu_percent` | Average CPU usage during sampling |
| `max_cpu_percent` | Maximum CPU usage during sampling |
| `process_count_max` | Maximum process count during sampling |
| `pdf_bytes` | Generated PDF size |
| `status` | `ok` or `error` |
| `error` | Error details |

### Process Measurement Method

`ProcessSampler` runs the following command every `0.1 seconds`:

```sh
ps -axo pid=,ppid=,rss=,%cpu=,comm=
```

The measurement targets are each worker process forked from the parent runner and their descendant processes. Ruby threads run inside the same process, so `process_count_max` does not include the thread count itself.

In other words, the aggregation includes not only the Ruby worker itself, but also `wkhtmltopdf` and Chrome/Chromium-based processes launched under it. When `concurrency` or `threads` is 2 or greater, `max_pss_kb` is the summed PSS of processes under concurrently running workers. RSS can easily double-count shared memory, so only PSS is displayed by default.

### Engine-Specific Execution Conditions

#### wkhtmltopdf

Command used:

```sh
/usr/bin/wkhtmltopdf
```

Specified by `WKHTMLTOPDF_BIN` in `docker-compose.yml`.

Options:

```sh
--quiet
--enable-local-file-access
```

HTML is read with `File.read` and passed to `wkhtmltopdf - output.pdf` through standard input.

#### grover

Gem used:

```text
grover
```

PDF generation options:

```ruby
format: "A4"
print_background: true
display_url: "http://example.com/<fixture>.html"
wait_until: "networkidle0"
```

HTML is read with `File.read` and passed to Grover. `display_url` is the display URL for the first request where Grover returns the HTML string, and does not depend on an actual network. Using a `.html` URL makes Chromium treat the body as HTML.

#### ferrum_pdf

Gem used:

```text
ferrum
```

Browser launch options:

```ruby
timeout: 60
browser_options:
  no-sandbox
  disable-dev-shm-usage
  disable-gpu
```

PDF generation options:

```ruby
format: :A4
print_background: true
```

HTML is read with `File.read` and passed to Ferrum with `page.content = html`.

In `cold` mode, the browser is started and terminated for each iteration.

In `warm` mode, the browser is started when each thread starts, and each iteration in that thread creates and destroys a page.

### HTML Cases

| case | File | Description |
|---|---|---|
| `light` | `html/light.html` | Small, text-focused HTML roughly equivalent to one page |
| `medium` | `html/medium.html` | Medium-sized HTML with tables, CSS, and SVG |
| `heavy` | `html/heavy.html` | Heavier HTML with multiple pages, tables, SVG, and CSS |
| `js` | `html/js.html` | HTML where JavaScript generates the DOM |

### Conditions of the Recently Created Three-Engine Comparison Page

File:

```text
results/charts/all-engines.html
```

This page combines the following three CSV files:

```text
results/raw/20260501-191915-747803-85613.csv
results/raw/20260501-191919-142167-85653.csv
results/raw/20260501-191919-151858-85654.csv
```

Included conditions:

| Engine | case | mode | concurrency | threads | iterations |
|---|---|---|---:|---:|---:|
| `wkhtmltopdf` | `light` | `cold` | `1` | `1` | `1` |
| `ferrum_pdf` | `light` | `cold` | `1` | `1` | `1` |
| `grover` | `light` | `cold` | `1` | `1` | `1` |

In other words, the current `all-engines.html` is a minimal smoke-test comparison, not a result from running the full default settings.

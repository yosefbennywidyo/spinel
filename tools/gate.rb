require "fileutils"
require "open3"
require "tmpdir"

module Gate
  IMAGE = "spinel-gate"
  CONTAINER = <<~'SH'
    tar -x -C /src && cd /src
    cache="vendor/prism vendor/rbs build/rubyspec build/optcarrot build/rubyboy"
    for d in $cache; do [ -d /cache/$d ] && mkdir -p $(dirname $d) && cp -a /cache/$d $d; done
    chown -R gate:gate /src
    runuser -u gate -- env HOME=/home/gate PATH="$PATH" GATE_JOBS="$GATE_JOBS" GATE_TARGET="$GATE_TARGET" TEST_SHARD="$TEST_SHARD" bash -c 'cd /src && git init -q && git add -A &&
      git -c user.email=gate@local -c user.name=gate commit -qm gate &&
      for i in 1 2 3 4 5; do make deps >/dev/null 2>&1 && break; sleep 5; done;
      t=${GATE_TARGET:-gate}; [ "$t" = gate ] || make -j${GATE_JOBS:-$(nproc)} all 2>&1; make -j${GATE_JOBS:-$(nproc)} "$t" 2>&1'
    rc=$?
    for d in $cache; do [ -d $d ] && [ ! -d /cache/$d ] && mkdir -p /cache/$(dirname $d) && cp -a $d /cache/$d; done
    echo "@@platform linux-$(uname -m) gcc-$(gcc -dumpfullversion)"
    echo "@@done ${GATE_TARGET:-gate} rc=$rc"
    exit $rc
  SH

  module_function

  def run(*cmd, env: {})
    out, st = Open3.capture2(env, *cmd, err: File::NULL, binmode: true)
    out if st.success?
  rescue SystemCallError
    nil
  end

  def git(*args, env: {}) = run("git", *args, env: env)&.strip

  # A file's bytes, whatever the locale: under a C locale git's output reads
  # as US-ASCII, and the scans below raised on a UTF-8 source.
  def show(spec) = run("git", "show", spec).to_s.b

  def master
    [ENV["GATE_MASTER"], "upstream/master", "origin/master"].compact
      .lazy.filter_map { |ref| git("rev-parse", "-q", "--verify", "#{ref}^{commit}") }.first
  end

  def merged_tree(base, commit) = git("merge-tree", "--write-tree", base, commit)

  def functions(src)
    out = {}
    name = start = nil
    src.each_line.with_index(1) do |line, i|
      if start.nil? && line !~ /\A(?:if|for|while|switch|return|else)\b/ &&
         (m = line.match(/\A(?:static\s+)?(?:inline\s+)?[\w\s*]+?\b(\w+)\s*\([^;]*\)\s*\{\s*\z/))
        name = m[1]
        start = i
      elsif start && line.start_with?("}")
        out[name] = [out[name].to_i, i - start + 1].max
        start = nil
      end
    end
    out
  end

  # The CRuby that judges a new test's .expected: tools/gate-ruby's pick
  # ($GATE_RUBY, else a Ruby 4.0 or later on PATH), or nil after a warning.
  def reference_ruby
    ruby = run("sh", File.join(__dir__, "gate-ruby")).to_s.strip
    return ruby unless ruby.empty?

    warn "gate: no Ruby 4.0 or later (set GATE_RUBY); .expected not checked against CRuby"
  end

  # `# spinel: not-cruby` in a test's first lines: its .expected is spinel's
  # own answer and legitimately differs from CRuby's.
  def not_cruby?(src) = src.lines.first(5).any? { |l| l.start_with?("# spinel: not-cruby") }

  def cruby(ruby, t, args)
    stdin = File.exist?("#{t}.stdin") ? "#{t}.stdin" : File::NULL
    IO.popen([ruby, "--enable-frozen-string-literal", "--external-encoding=UTF-8", t, *args], in: stdin, err: File::NULL) do |io|
      reader = Thread.new { io.read }
      next reader.value if reader.join(20)

      Process.kill(:KILL, io.pid)
      reader.join
      nil
    end
  end

  # The function-size rule (#7033), whole: emit_call_body only shrinks, and a
  # function past FUNCTION_LIMIT lines neither grows nor is added. Returns
  # the complaint for function fn, `was` lines at HEAD (nil when new) and n
  # lines staged, or nil; check refuses the commit on it.
  FUNCTION_LIMIT = 1000

  def function_size_error(fn, was, n)
    if fn == "emit_call_body" && was && n > was
      "emit_call_body grew #{was} -> #{n}; it only shrinks (#7033)"
    elsif was && was > FUNCTION_LIMIT && n > was
      "#{fn} grew #{was} -> #{n}; add the arm through a helper or its receiver file"
    elsif was.nil? && n > FUNCTION_LIMIT
      "new function #{fn} is #{n} lines"
    end
  end

  # The change check judges: the staged one (the index against HEAD, the
  # pre-commit hook's), or a commit range's (head against its merge base
  # with base, CI's view of a pull request). `before` and `after` prefix a
  # path to name its blob, `diff` selects the change for git diff, and
  # `tree` is what the working tree must match for CRuby to run a test there.
  Change = Struct.new(:before, :after, :diff, :tree)

  def staged = Change.new("HEAD:", ":", ["--cached"], [])

  def range(base, head)
    b = git("rev-parse", "-q", "--verify", "#{base}^{commit}") or return
    h = git("rev-parse", "-q", "--verify", "#{head}^{commit}") or return
    mb = git("merge-base", b, h) or return
    Change.new("#{mb}:", "#{h}:", [mb, h], [h])
  end

  # The test harness (RUN_ONE_TEST) reads test/foo.rb.expected and, without
  # one, runs CRuby for the expected output; a test/foo.expected is never read.
  def no_expected_error(t, changed)
    alt = t.sub(/\.rb\z/, ".expected")
    hint = changed.include?(alt) || File.exist?(alt) ? "; rename #{alt}: the harness reads only #{t}.expected" : ""
    "#{t}: no #{t}.expected#{hint}"
  end

  def check(change = staged)
    errors = []
    changed = git("diff", *change.diff, "--name-only", "--diff-filter=ACMR").to_s.split("\n")
    changed.grep(%r{\Asrc/.*\.c\z}).each do |f|
      before = functions(show("#{change.before}#{f}"))
      functions(show("#{change.after}#{f}")).each do |fn, n|
        e = function_size_error(fn, before[fn], n) and errors << "#{f}: #{e}"
      end
    end
    added = git("diff", *change.diff, "--name-only", "--diff-filter=A", "--", "test/*.rb").to_s.split("\n")
      .reject { |t| t.count("/") > 1 }
    ruby = reference_ruby unless added.empty?
    added.each do |t|
      src = show("#{change.after}#{t}")
      errors << "#{t}: use Dir.tmpdir, not a fixed /tmp path" if src.match?(%r{["']/tmp/})
      if !src.include?("# spinel: int64") && src.scan(/(?<![\w.])\d[\d_]{9,}/).any? { |n| n.delete("_").to_i >= 2**31 }
        warn "gate: #{t} has literals past 2^31 but no `# spinel: int64` marker"
      end
      next errors << no_expected_error(t, changed) unless changed.include?("#{t}.expected")
      next if !ruby || not_cruby?(src)

      unless git("diff", "--quiet", *change.tree, "--", t, "#{t}.args", "#{t}.stdin")
        next warn("gate: #{t} differs in the working tree; .expected not checked")
      end

      out = cruby(ruby, t, File.exist?("#{t}.args") ? File.binread("#{t}.args").split : [])
      next warn("gate: #{t} ran over 20s under CRuby; .expected not checked") unless out

      errors << "#{t}: .expected differs from `#{ruby} --enable-frozen-string-literal #{t}`" if out.b != show("#{change.after}#{t}.expected")
    end
    errors.each { |e| warn "gate: #{e}" }
    errors.empty? ? 0 : 1
  end

  def check_range(base, head)
    change = range(base, head) or return warn("gate: no merge base for #{base} and #{head}; fetch them") || 2
    check(change)
  end

  # `--shard K/N`: the K-th of N slices of the corpus, 1-based. nil unless
  # 1 <= K <= N.
  def parse_shard(spec)
    k, n = spec.to_s.split("/", 2).map { |x| Integer(x, exception: false) }
    k && n && n >= 1 && k.between?(1, n) ? [k, n] : nil
  end

  # The legs of `make gate` that a sharded run must still pass, unsharded, in
  # one report each (gate-rubyspec only when GATE_RUBYSPEC is not 0).
  def required_legs
    %w[gate-test gate-bench gate-optcarrot gate-rubyboy gate-props] + (ENV["GATE_RUBYSPEC"] == "0" ? [] : %w[gate-rubyspec])
  end

  # The report beside a run's log: one key=value per line, read by merge.
  def write_report(path, fields)
    File.write(path, fields.map { |k, v| "#{k}=#{v}\n" }.join)
  end

  def read_report(path)
    File.readlines(path, chomp: true).filter_map { |l| l.split("=", 2) if l.include?("=") }.to_h
  end

  # Merges shard reports into one verdict. It names itself `gate-sharded`, not
  # `gate:`: no single `make gate` ran, so the official line never appears.
  def merge(paths)
    reports = paths.map { |p| read_report(p) }
    problems = []
    trees = reports.map { _1["tree"] }.uniq
    masters = reports.map { _1["master"] }.uniq
    problems << "reports name #{trees.size} trees; they must name one" unless trees.size == 1
    problems << "reports name #{masters.size} masters; they must name one" unless masters.size == 1
    tests = reports.select { _1["target"] == "gate-test" }
    sharded, whole = tests.partition { _1["shard"].to_s.include?("/") }
    if sharded.any? && whole.any?
      problems << "both sharded and unsharded gate-test reports"
    elsif sharded.empty? && whole.empty?
      problems << "no gate-test report"
    end
    if sharded.any?
      ns = sharded.map { parse_shard(_1["shard"])&.last }.uniq
      if ns.size == 1 && ns.first
        ks = sharded.map { parse_shard(_1["shard"]).first }.sort
        missing = (1..ns.first).to_a - ks
        problems << "missing shards #{missing.join(",")} of #{ns.first}" unless missing.empty?
        dups = ks.select { |k| ks.count(k) > 1 }.uniq
        problems << "duplicate shards #{dups.join(",")}" unless dups.empty?
      else
        problems << "shard reports disagree on N: #{ns.inspect}"
      end
      sharded.reject { _1["rc"] == "0" }.each { problems << "shard #{_1["shard"]} rc=#{_1["rc"]}" }
    end
    whole.reject { _1["rc"] == "0" }.each { problems << "gate-test rc=#{_1["rc"]}" }
    (required_legs - ["gate-test"]).each do |leg|
      r = reports.find { _1["target"] == leg }
      problems << "#{leg}: no report" unless r
      problems << "#{leg}: rc=#{r["rc"]}" if r && r["rc"] != "0"
    end
    pass = tests.sum { _1["pass"].to_i }
    fail = tests.sum { _1["fail"].to_i }
    error = tests.sum { _1["error"].to_i }
    problems << "tests: #{fail} fail, #{error} error" if fail + error > 0
    if problems.empty?
      puts "Tests: #{pass} pass, #{fail} fail, #{error} error"
      puts "gate-sharded: ALL GREEN (tree #{trees.first[0, 12]} master #{masters.first[0, 12]})"
      0
    else
      problems.each { warn "gate: #{_1}" }
      1
    end
  end

  def linux(argv = [])
    target, shard = "gate", nil
    until argv.empty?
      case (opt = argv.shift)
      when "--target" then target = argv.shift or abort "gate: --target needs a make target"
      when "--shard" then shard = argv.shift or abort "gate: --shard needs K/N"
      else abort "gate: unknown option #{opt}"
      end
    end
    if shard
      abort "gate: --shard needs K/N with 1 <= K <= N" unless parse_shard(shard)
      abort "gate: --shard applies to gate-test only" unless target == "gate-test"
    end
    Dir.chdir(git("rev-parse", "--show-toplevel") || abort("gate: not in a git checkout"))
    base = master or abort "gate: no upstream/master or origin/master; set GATE_MASTER"
    tree = merged_tree(base, "HEAD") or abort "gate: HEAD does not merge cleanly with #{base[0, 12]}; rebase first"
    run("docker", "image", "inspect", IMAGE) || system("docker", "build", "-q", "-t", IMAGE, "tools/gate", out: File::NULL) ||
      abort("gate: docker build of #{IMAGE} failed")
    log = ENV["GATE_LOG"] || File.join(git("rev-parse", "--git-dir"), "gate-linux.log")
    puts "gate: tree #{tree[0, 12]} merged with master #{base[0, 12]} -> #{log}"
    ENV["GATE_TARGET"] = target
    ENV["TEST_SHARD"] = shard.to_s
    ok = IO.popen(["git", "archive", tree]) do |archive|
      system("docker", "run", "--rm", "-i", "-e", "GATE_JOBS", "-e", "GATE_TARGET", "-e", "TEST_SHARD",
             "-v", "spinel-gate-cache:/cache", IMAGE, "bash", "-c", CONTAINER, in: archive, out: log, err: [:child, :out])
    end
    text = File.read(log)
    puts text.lines.grep(/\A(Tests:|scale-test|gate:)/).last(7)
    rc = text[/^@@done #{Regexp.escape(target)} rc=(\d+)$/, 1] || "missing"
    counts = text.scan(/^Tests: (\d+) pass, (\d+) fail, (\d+) error$/).last || [0, 0, 0]
    write_report("#{log}.report", tree: tree, master: base, target: target, shard: shard.to_s, rc: rc,
                 pass: counts[0], fail: counts[1], error: counts[2])
    abort "gate: failed; see #{log}" unless ok && rc == "0" && (target != "gate" || text.include?("gate: ALL GREEN"))
  end
end

if $PROGRAM_NAME == __FILE__
  case ARGV.shift
  when "check" then exit Gate.check
  when "check-range" then exit Gate.check_range(ARGV.fetch(0), ARGV.fetch(1))
  when "linux" then Gate.linux(ARGV)
  when "merge" then exit Gate.merge(ARGV)
  else abort "usage: ruby tools/gate.rb check | check-range BASE HEAD | linux [--target T] [--shard K/N] | merge REPORT..."
  end
end

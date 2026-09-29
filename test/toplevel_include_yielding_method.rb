# A method of a module included at the top level is callable bare. A yielding
# one exists only inlined at its call sites, and the call was left to the
# top-level-include arm, which named a function that was never emitted: the
# link failed on an undefined sp_<Module>_<method>. A test helper written this
# way (`include Testing` then `check("...") { ... }`) is the common case.
module Testing
  def check(label)
    raise "FAIL: #{label}" unless yield
    puts "ok #{label}"
  end

  def twice(x) = yield(yield(x))
end

module Outer
  module Blocks
    def run_blk(label, &blk)
      puts "#{label}: #{blk.call}"
    end
  end
end

include Testing
include Outer::Blocks

check("flat yield") { 1 + 1 == 2 }
p twice(3) { |v| v * 2 }
run_blk("blk") { "called" }

def helper_user = twice(1) { |v| v + 10 }
p helper_user

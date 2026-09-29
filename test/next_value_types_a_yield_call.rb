# A block that can leave through `next v` answers v or its tail. The call of a
# yield-tailed method was typed from the block's tail alone. With a nil tail
# the call was nil, and `p` printed "nil" for a block that answered true. With
# a String tail, the boxed union was stored into a `const char *` and the C did
# not compile.
def run = yield

def pick(flag) = run { next true if flag; nil }

p pick(true)
p pick(false)
p run { next true if 1 == 1; "str" }
p run { next 5 if 1 == 2; "tail" }
p run { next 5 if 1 == 1; "tail" }

def each_twice
  yield 1
  yield 2
end

seen = []
each_twice { |i| next if i == 1; seen << i }
p seen

# The same with an untyped tail, a method no class defines: taken through
# `next`, the call answers the next value. Reached, the tail raises
# NoMethodError. Its raise was assigned into the slot the next value types,
# and the C did not compile.
class Gadget
end

p run { next true if 1 == 1; Gadget.new.save }
p run { next 5 if 1 == 1; Gadget.new.save }
begin
  p run { next 5 if 1 == 2; Gadget.new.save }
rescue NoMethodError => e
  puts "NoMethodError: #{e.message}"
end

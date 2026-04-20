#!/usr/bin/env ruby
# Pocket Lab v2.9 — Ruby 3.4 in-chroot verification test
# Run: chroot /mnt/debian /usr/local/bin/ruby /tmp/ruby_test.rb

puts "=== Pocket Lab Ruby 3.4 Test ==="
puts "Version:  #{RUBY_VERSION}"
puts "Platform: #{RUBY_PLATFORM}"

puts "\n--- Core ---"
raise "FAIL" unless 1 + 1 == 2
puts "1+1 = #{1+1} ✓"
x = [1,2,3].map { |n| n * 2 }
raise "FAIL" unless x == [2,4,6]
puts "map: #{x.inspect} ✓"

puts "\n--- Date ---"
require "date"
puts "Date.today: #{Date.today} ✓"

puts "\n--- Set ---"
require "set"
s = Set.new([1,2,3,2,1])
raise "FAIL" unless s.size == 3
puts "Set: #{s.inspect} ✓"

puts "\n--- Base64 ---"
require "base64"
enc = Base64.encode64("hello").strip
raise "FAIL" unless enc == "aGVsbG8="
puts "Base64: #{enc} ✓"

puts "\n--- Digest ---"
require "digest"
md5 = Digest::MD5.hexdigest("hello")
raise "FAIL" unless md5 == "5d41402abc4b2a76b9719d911017c592"
puts "MD5: #{md5} ✓"

puts "\n--- JSON ---"
require "json"
j = JSON.generate({ruby: RUBY_VERSION, ok: true})
puts "JSON: #{j} ✓"

puts "\n--- OpenStruct ---"
require "ostruct"
o = OpenStruct.new(name: "iSH", version: RUBY_VERSION)
raise "FAIL" unless o.name == "iSH"
puts "OpenStruct: #{o.name} v#{o.version} ✓"

puts "\n=== ALL TESTS PASSED ==="

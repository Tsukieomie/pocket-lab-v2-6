#!/usr/bin/env ruby
# Pocket Lab v2.8 — Ruby in-chroot verification test
# Run from inside debian# chroot: ruby /tmp/ruby_test.rb
# Or from iSH host: chroot /mnt/debian /usr/local/bin/ruby /tmp/ruby_test.rb

puts "=== Pocket Lab Ruby Test ==="
puts "Ruby version: #{RUBY_VERSION}"
puts "Platform:     #{RUBY_PLATFORM}"

puts "\n--- Basic arithmetic ---"
raise "FAIL" unless 1 + 1 == 2
puts "1+1 = #{1+1} ✓"

puts "\n--- Array/block ops ---"
x = [1, 2, 3].map { |n| n * 2 }
raise "FAIL" unless x == [2, 4, 6]
puts "map: #{x.inspect} ✓"

puts "\n--- Stdlib: Date ---"
require "date"
d = Date.today
puts "Date.today: #{d} ✓"

puts "\n--- Stdlib: Set ---"
require "set"
s = Set.new([1, 2, 3, 2, 1])
raise "FAIL" unless s.size == 3
puts "Set dedup: #{s.inspect} ✓"

puts "\n--- Stdlib: Base64 ---"
require "base64"
enc = Base64.encode64("hello").strip
raise "FAIL" unless enc == "aGVsbG8="
puts "Base64: #{enc} ✓"

puts "\n--- Stdlib: Digest ---"
require "digest"
md5 = Digest::MD5.hexdigest("hello")
raise "FAIL" unless md5 == "5d41402abc4b2a76b9719d911017c592"
puts "MD5: #{md5} ✓"

puts "\n--- Stdlib: OpenStruct ---"
require "ostruct"
o = OpenStruct.new(name: "iSH", env: "debian-chroot")
raise "FAIL" unless o.name == "iSH"
puts "OpenStruct: #{o.name} / #{o.env} ✓"

puts "\n=== ALL TESTS PASSED ==="

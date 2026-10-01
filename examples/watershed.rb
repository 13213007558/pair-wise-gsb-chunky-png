#!/usr/bin/env ruby
# frozen-string-literal: true

# Example: marker-controlled watershed segmentation of a height map.
#
# Builds a height map with three valleys, places one marker in each of them
# plus a fourth marker on a hill, and segments the image. Everything outside
# a circular mask is excluded from the segmentation. The resulting partition
# is rendered to examples/watershed_segmentation.png: one color per region,
# black watershed lines, transparent masked-out pixels.
#
# Run from the repository root:
#
#   ruby -Ilib examples/watershed.rb

require "chunky_png"

WIDTH = 96
HEIGHT = 96
CENTERS = [[24, 24], [72, 28], [44, 68]].freeze
MARKERS = {
  [24, 24] => 1,
  [72, 28] => 2,
  [44, 68] => 3,
  [76, 76] => 4
}.freeze

# Distance to the nearest valley center: three basins separated by ridges.
heights = Array.new(HEIGHT) do |y|
  Array.new(WIDTH) do |x|
    CENTERS.map { |cx, cy| Math.hypot(x - cx, y - cy) }.min.round
  end
end

markers = Array.new(HEIGHT) { Array.new(WIDTH, 0) }
MARKERS.each { |(x, y), label| markers[y][x] = label }

# Only segment inside a circle around the image center.
mask = Array.new(HEIGHT) do |y|
  Array.new(WIDTH) do |x|
    Math.hypot(x - WIDTH / 2, y - HEIGHT / 2) <= 44
  end
end

result = ChunkyPNG::Watershed.segment(heights, markers, connectivity: 8, mask: mask)

puts "Region sizes:"
result.labels.flatten.compact.each_with_object(Hash.new(0)) { |label, counts| counts[label] += 1 }
  .sort.each do |label, count|
    name = case label
    when ChunkyPNG::Watershed::BOUNDARY then "watershed line"
    when ChunkyPNG::Watershed::UNLABELED then "unlabeled"
    else "region #{label}"
    end
    puts format("  %-14s %4d pixels", name, count)
  end

output = File.join(__dir__, "watershed_segmentation.png")
result.to_image.resample_nearest_neighbor(WIDTH * 4, HEIGHT * 4).save(output)
puts "Wrote #{output}"

require 'heap_info'

rule ".json" => ".png" do |t|
  p t.name => t.source
  #heap = Heap.read t.source
  #heap.to_png.save t.name, interlace: true
end

task :default => Rake::FileList["*.json"]

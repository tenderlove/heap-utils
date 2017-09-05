require 'json'
require 'fiddle'
require 'chunky_png'

module HeapUtils
  SIZEOF_HEAP_PAGE_HEADER_STRUCT = Fiddle::SIZEOF_VOIDP

  HEAP_PAGE_ALIGN_LOG     = 14
  HEAP_PAGE_ALIGN         = 1 << HEAP_PAGE_ALIGN_LOG
  HEAP_PAGE_ALIGN_MASK    = ~(~0 << HEAP_PAGE_ALIGN_LOG)
  # SIZEOF_RVALUE           = 56 # Only when GC_DEBUG is enabled
  SIZEOF_RVALUE           = 40
  REQUIRED_SIZE_BY_MALLOC = Fiddle::SIZEOF_SIZE_T * 5 # padding needed by malloc
  HEAP_PAGE_SIZE          = HEAP_PAGE_ALIGN - REQUIRED_SIZE_BY_MALLOC
  HEAP_PAGE_OBJ_LIMIT     = (HEAP_PAGE_SIZE - SIZEOF_HEAP_PAGE_HEADER_STRUCT) / SIZEOF_RVALUE

  def NUM_IN_PAGE object_address
    (object_address & HEAP_PAGE_ALIGN_MASK) / SIZEOF_RVALUE
  end

  def GET_PAGE_BODY object_address
    object_address & ~HEAP_PAGE_ALIGN_MASK
  end

  # Calculate the address given an object id
  def id_to_addr object_id
    object_id << 1
  end

  # Calculate page body address from object address
  def page_addr_from_object_addr object_address
    GET_PAGE_BODY(object_address)
  end

  # Offset from the start of a page.  E.g. the address for the 4th object in
  # a page will return 4
  def page_number_from_object_addr object_address
    NUM_IN_PAGE(object_address)
  end

  class Slot < Struct.new :obj
    def pinned?
      obj.key?('flags') && obj['flags']['pinned']
    end

    def address
      obj['address'].to_i 16
    end

    def empty?
      false
    end
  end

  class EmptySlot < Struct.new :address
    def empty?
      true
    end
  end

  class Page < Struct.new :addr, :start, :total_slots
    def initialize addr, start, total_slots
      super
      @objects = []
    end

    attr_reader :objects

    def finish
      start + total_slots
    end

    def add_object obj
      @objects << Slot.new(obj)
    end

    def each_slot
      return enum_for(:each_slot) unless block_given?

      objs = objects.sort_by(&:address)
      total_slots.times do |i|
        expected = start + (i * SIZEOF_RVALUE)
        if objs.any? && objs.first.address == expected
          yield objs.shift
        else
          yield EmptySlot.new expected
        end
      end
    end
  end

  # Get a page given an address
  def page_for_address addr
    page page_addr_from_object_addr addr
  end

  # Get a page for a live object
  def page_for_object obj
    page_for_address id_to_addr obj.object_id
  end

  def page page_body
    limit = HEAP_PAGE_OBJ_LIMIT
    start = page_body + SIZEOF_HEAP_PAGE_HEADER_STRUCT

    if start % SIZEOF_RVALUE != 0
      delta = SIZEOF_RVALUE - (start % SIZEOF_RVALUE)
      start = start + delta
      limit = (HEAP_PAGE_SIZE - (start - page_body)) / SIZEOF_RVALUE
    end

    Page.new page_body, start, limit
  end
end

class Heap
  include HeapUtils

  def initialize
    @pages = {}
  end

  # Get a page given an address
  def page addr
    @pages[addr] ||= super
  end

  def pages
    @pages.values
  end

  def self.read file
    heap = Heap.new

    File.open(file, 'r') do |f|
      f.each_line do |line|
        object = JSON.load line
        if object['type'] != 'ROOT'
          address = object['address'].to_i 16
          page    = heap.page_for_address address
          page.add_object object
        end
      end
    end
    heap
  end

  def to_png
    width = pages.size * 2
    height = (HeapUtils::HEAP_PAGE_OBJ_LIMIT * 2)

    png = ChunkyPNG::Image.new(width, height, ChunkyPNG::Color::TRANSPARENT)

    pinning = pages.sort_by { |k| v = k.objects; v.select(&:pinned?).length }.reverse

    pinning.each_with_index do |page, i|
      i = i * 2

      page.each_slot.with_index do |slot, j|
        unless slot.empty?
          j = j * 2
          if slot.pinned?
            png[i, j] = ChunkyPNG::Color.rgba(255, 0, 0, 255)
            png[i + 1, j] = ChunkyPNG::Color.rgba(255, 0, 0, 255)
            png[i, j + 1] = ChunkyPNG::Color.rgba(255, 0, 0, 255)
            png[i + 1, j + 1] = ChunkyPNG::Color.rgba(255, 0, 0, 255)
          else
            png[i, j] = ChunkyPNG::Color.rgba(0, 255, 0, 255)
            png[i + 1, j] = ChunkyPNG::Color.rgba(0, 255, 0, 255)
            png[i, j + 1] = ChunkyPNG::Color.rgba(0, 255, 0, 255)
            png[i + 1, j + 1] = ChunkyPNG::Color.rgba(0, 255, 0, 255)
          end
        end
      end
    end

    png
  end
end

if __FILE__ == $0
  heap = Heap.read ARGV[0]
  p :PAGES =>  heap.pages.size
  p :PINNED => heap.pages.flat_map(&:objects).select(&:pinned?).count
  p :PINNED_RATIO => heap.pages.flat_map(&:objects).select(&:pinned?).count / heap.pages.flat_map(&:objects).count.to_f
  p :TOTAL => heap.pages.flat_map(&:objects).count

  heap.to_png.save('filename.png', :interlace => true)
end

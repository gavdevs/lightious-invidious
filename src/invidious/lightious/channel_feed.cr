require "json"

module Invidious::Lightious::ChannelFeed
  extend self

  PER_SOURCE_PAGE_SIZE          = 30
  MAX_PAGE_ITEMS                = PER_SOURCE_PAGE_SIZE * 2
  MAX_CURSOR_BYTES              =     6_000
  MAX_SOURCE_CONTINUATION_BYTES =     5_500
  MAX_SOURCE_OFFSET             = 1_000_000
  DEFAULT_RECENT_LIMIT          =         3
  MAX_RECENT_LIMIT              =         5

  record Position,
    complete : Bool,
    continuation : String?,
    offset : Int32 do
    def self.initial : self
      new(false, nil, 0)
    end

    def self.finished : self
      new(true, nil, 0)
    end
  end

  record Cursor,
    uploads : Position,
    streams : Position do
    def complete? : Bool
      uploads.complete && streams.complete
    end
  end

  record Window,
    start : Int32,
    size : Int32,
    next_position : Position

  record Entry,
    id : String,
    title : String,
    author : String,
    author_id : String,
    published : Time,
    views : Int64,
    length_seconds : Int32,
    premiere_timestamp : Time?,
    live_now : Bool do
    def upcoming? : Bool
      premiere_timestamp.try { |value| value.to_unix > 0 } || false
    end
  end

  # Only public channel metadata is cached, before profile limits, quarantine,
  # or watched filtering. Both memory and freshness are bounded. Failed fetches
  # never enter this cache, so a retry can recover immediately.
  class RecentCache
    private record CachedPage, entries : Array(Entry), stored_at : Time::Span

    @pages = {} of String => CachedPage
    @mutex = Mutex.new

    def initialize(@max_channels : Int32 = 256, @ttl : Time::Span = 5.minutes)
      raise ArgumentError.new("max_channels must be positive") unless @max_channels > 0
      raise ArgumentError.new("ttl must be positive") unless @ttl > Time::Span.zero
    end

    def get(channel_id : String, now : Time::Span = Time.monotonic) : Array(Entry)?
      @mutex.synchronize do
        if page = @pages[channel_id]?
          return page.entries.dup if now - page.stored_at < @ttl
          @pages.delete(channel_id)
        end
        nil
      end
    end

    def put(channel_id : String, entries : Array(Entry), now : Time::Span = Time.monotonic) : Nil
      @mutex.synchronize do
        @pages.reject! { |_, page| now - page.stored_at >= @ttl }
        if !@pages.has_key?(channel_id) && @pages.size >= @max_channels
          oldest = @pages.min_by { |_, page| page.stored_at }.first
          @pages.delete(oldest)
        end
        @pages[channel_id] = CachedPage.new(entries.first(MAX_PAGE_ITEMS), now)
      end
    end
  end

  def initial_cursor(has_uploads : Bool, has_streams : Bool) : Cursor
    Cursor.new(
      has_uploads ? Position.initial : Position.finished,
      has_streams ? Position.initial : Position.finished,
    )
  end

  def constrain(cursor : Cursor, has_uploads : Bool, has_streams : Bool) : Cursor
    Cursor.new(
      has_uploads ? cursor.uploads : Position.finished,
      has_streams ? cursor.streams : Position.finished,
    )
  end

  # A source page is replayed with an offset when it contains more than the
  # per-source allowance. This keeps the public response bounded without
  # silently dropping items before advancing the upstream continuation.
  def page_window(total : Int32, position : Position, next_continuation : String?) : Window
    return Window.new(0, 0, Position.finished) if position.complete

    start = Math.min(position.offset, total)
    size = Math.min(PER_SOURCE_PAGE_SIZE, total - start)
    consumed = start + size
    next_position = if consumed < total
                      Position.new(false, position.continuation, consumed)
                    elsif continuation = normalized_continuation(next_continuation)
                      Position.new(false, continuation, 0)
                    else
                      Position.finished
                    end

    Window.new(start, size, next_position)
  end

  def merge(pages : Array(Array(Entry)), limit : Int32 = MAX_PAGE_ITEMS, preserve_order : Bool = false) : Array(Entry)
    by_id = {} of String => Entry
    pages.each do |page|
      page.each do |entry|
        if existing = by_id[entry.id]?
          by_id[entry.id] = entry if preferred?(entry, existing)
        else
          by_id[entry.id] = entry
        end
      end
    end

    source_order = {} of String => Int32
    by_id.each_key.with_index { |id, index| source_order[id] = index }
    by_id.values.sort! do |left, right|
      published_order = right.published <=> left.published
      tie_order = preserve_order ? source_order[left.id] <=> source_order[right.id] : left.id <=> right.id
      published_order == 0 ? tie_order : published_order
    end.first(limit)
  end

  # Upstream pages are already newest-first. Relative labels such as "one
  # month ago" are decoded against a new clock value for each item, so later
  # items can acquire slightly later timestamps. Preserve the source order
  # rather than promoting older uploads on this parser-induced clock drift.
  def newest_source(entries : Array(Entry)) : Array(Entry)
    previous : Time? = nil
    entries.map do |entry|
      published = previous.try { |value| Math.min(value, entry.published) } || entry.published
      previous = published
      entry.copy_with(published: published)
    end
  end

  # A fixed release window, independent of any watched history. Completion is
  # filtered by the phone afterwards, so finishing a video cannot backfill an
  # older upload. Callers fetch only the first page of each source.
  def recent_window(pages : Array(Array(Entry)), limit : Int32) : Array(Entry)
    merge(pages, preserve_order: true).reject { |entry| entry.live_now || entry.upcoming? }
      .first(limit.clamp(1, MAX_RECENT_LIMIT))
  end

  # Keep each channel's already-bounded window. The archive-page limit must
  # not silently truncate subscriptions when many channels have been saved.
  def combine_recent(windows : Array(Array(Entry))) : Array(Entry)
    merge(windows, windows.sum(&.size), preserve_order: true)
  end

  def encode(cursor : Cursor) : String
    JSON.build do |json|
      json.object do
        json.field "v", 1
        write_position(json, "u", cursor.uploads)
        write_position(json, "l", cursor.streams)
      end
    end
  end

  def decode(raw : String) : Cursor?
    return nil if raw.empty? || raw.bytesize > MAX_CURSOR_BYTES

    object = JSON.parse(raw).as_h?
    return nil unless object
    return nil unless object["v"]?.try(&.as_i?) == 1

    uploads = read_position(object["u"]?)
    streams = read_position(object["l"]?)
    return nil unless uploads && streams

    Cursor.new(uploads, streams)
  rescue JSON::ParseException
    nil
  end

  private def write_position(json : JSON::Builder, name : String, position : Position)
    json.field name do
      json.object do
        json.field "d", position.complete
        json.field "o", position.offset
        json.field "c" do
          if continuation = position.continuation
            json.string continuation
          else
            json.null
          end
        end
      end
    end
  end

  private def read_position(value : JSON::Any?) : Position?
    object = value.try(&.as_h?)
    return nil unless object

    complete = object["d"]?.try(&.as_bool?)
    raw_offset = object["o"]?.try(&.as_i?)
    return nil if complete.nil? || raw_offset.nil?
    return nil unless raw_offset >= 0 && raw_offset <= MAX_SOURCE_OFFSET

    continuation_value = object["c"]?
    continuation = continuation_value.try(&.as_s?)
    return nil if continuation && (continuation.empty? || continuation.bytesize > MAX_SOURCE_CONTINUATION_BYTES)
    return nil if complete && (continuation || raw_offset != 0)

    Position.new(complete, continuation, raw_offset.to_i32)
  end

  private def normalized_continuation(value : String?) : String?
    value unless value.nil? || value.empty?
  end

  private def preferred?(candidate : Entry, existing : Entry) : Bool
    candidate_priority = candidate.live_now ? 2 : (candidate.upcoming? ? 1 : 0)
    existing_priority = existing.live_now ? 2 : (existing.upcoming? ? 1 : 0)
    candidate_priority > existing_priority
  end
end

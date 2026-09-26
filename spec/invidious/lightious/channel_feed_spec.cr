require "spectator"
require "../../../src/invidious/lightious/channel_feed"

alias LightiousChannelFeed = Invidious::Lightious::ChannelFeed

module ChannelFeedSpecHelpers
  extend self

  def entry(id : String, published : Int64, *, live = false, upcoming = false)
    LightiousChannelFeed::Entry.new(
      id: id,
      title: "Video #{id}",
      author: "Channel",
      author_id: "UC_x5XG1OV2P6uZZ5FSM9Ttw",
      published: Time.unix(published),
      views: 1_i64,
      length_seconds: 60,
      premiere_timestamp: upcoming ? Time.unix(published + 60) : nil,
      live_now: live,
    )
  end
end

Spectator.describe Invidious::Lightious::ChannelFeed do
  it "round-trips compact cursor state and rejects malformed state" do
    cursor = LightiousChannelFeed::Cursor.new(
      LightiousChannelFeed::Position.new(false, "uploads-next", 12),
      LightiousChannelFeed::Position.initial,
    )

    encoded = described_class.encode(cursor)
    expect(JSON.parse(encoded).as_h.has_key?("s")).to be_false
    expect(described_class.decode(encoded)).to eq(cursor)
    expect(described_class.decode(%({"v":1,"u":{"d":true,"o":1,"c":null}}))).to be_nil
    expect(described_class.decode("x" * 6_001)).to be_nil
  end

  it "replays oversized source pages before advancing their continuation" do
    first = described_class.page_window(75, LightiousChannelFeed::Position.initial, "next-page")
    second = described_class.page_window(75, first.next_position, "next-page")
    third = described_class.page_window(75, second.next_position, "next-page")

    expect({first.start, first.size, first.next_position.offset}).to eq({0, 30, 30})
    expect({second.start, second.size, second.next_position.offset}).to eq({30, 30, 60})
    expect({third.start, third.size}).to eq({60, 15})
    expect(third.next_position.continuation).to eq("next-page")
    expect(third.next_position.offset).to eq(0)
  end

  it "deduplicates, prefers live metadata, and orders newest first" do
    duplicate_upload = ChannelFeedSpecHelpers.entry("AAAAAAAAAAA", 100)
    duplicate_live = ChannelFeedSpecHelpers.entry("AAAAAAAAAAA", 90, live: true)
    newest_upload = ChannelFeedSpecHelpers.entry("BBBBBBBBBBB", 200)

    merged = described_class.merge([
      [duplicate_live],
      [newest_upload],
      [duplicate_upload],
    ])

    expect(merged.map(&.id)).to eq(["BBBBBBBBBBB", "AAAAAAAAAAA"])
    expect(merged.last.live_now).to be_true
  end

  it "bounds every unified response" do
    entries = Array.new(100) do |index|
      ChannelFeedSpecHelpers.entry("video-#{index}", index.to_i64)
    end

    expect(described_class.merge([entries]).size).to eq(60)
  end

  it "selects only recent finished releases before any watched filtering" do
    uploads = [
      ChannelFeedSpecHelpers.entry("old", 100),
      ChannelFeedSpecHelpers.entry("newest", 400),
      ChannelFeedSpecHelpers.entry("second", 300),
      ChannelFeedSpecHelpers.entry("third", 200),
      ChannelFeedSpecHelpers.entry("upcoming", 600, upcoming: true),
    ]
    streams = [
      ChannelFeedSpecHelpers.entry("live", 500, live: true),
      ChannelFeedSpecHelpers.entry("second", 300),
    ]

    window = described_class.recent_window([uploads, streams], 3)
    expect(window.map(&.id)).to eq(["newest", "second", "third"])
    # The client hides completion after receiving this fixed window. There is
    # no continuation or callback that could pull "old" in to replace it.
    expect(window.reject { |entry| entry.id == "newest" }.map(&.id)).to eq(["second", "third"])
  end

  it "combines all channel windows without the archive page cap" do
    windows = Array.new(25) do |channel|
      Array.new(3) do |index|
        ChannelFeedSpecHelpers.entry("#{channel}-#{index}", (channel * 3 + index).to_i64)
      end
    end
    combined = described_class.combine_recent(windows)
    expect(combined.size).to eq(75)
    expect(combined.first.id).to eq("24-2")
    expect(combined.last.id).to eq("0-0")
    expect(described_class.combine_recent([] of Array(LightiousChannelFeed::Entry))).to be_empty
  end

  it "preserves newest source order when relative-date parsing moves the clock forward" do
    published = Time.unix(1_700_000_000)
    source = ["newest", "second", "third", "older"].map_with_index do |id, index|
      ChannelFeedSpecHelpers.entry(id, published.to_unix)
        .copy_with(published: published + index.microseconds)
    end
    window = described_class.recent_window([described_class.newest_source(source)], 3)
    expect(window.map(&.id)).to eq(["newest", "second", "third"])
    expect(window.map(&.published).uniq).to eq([published])
  end

  it "bounds the per-channel setting and preserves short windows" do
    entries = Array.new(10) { |index| ChannelFeedSpecHelpers.entry("#{index}", index.to_i64) }
    expect(described_class.recent_window([entries], 99).size).to eq(5)
    expect(described_class.recent_window([entries], 0).size).to eq(1)
    expect(described_class.recent_window([entries.first(2)], 5).size).to eq(2)
  end

  it "expires cached channel pages and bounds retained channels" do
    cache = LightiousChannelFeed::RecentCache.new(max_channels: 2, ttl: 5.minutes)
    start = Time.instant
    page = [ChannelFeedSpecHelpers.entry("one", 100)]
    cache.put("channel-one", page, start)
    cache.put("channel-two", page, start + 1.second)
    cache.put("channel-three", page, start + 2.seconds)

    expect(cache.get("channel-one", start + 3.seconds)).to be_nil
    expect(cache.get("channel-two", start + 3.seconds)).not_to be_nil
    expect(cache.get("channel-two", start + 301.seconds)).to be_nil
    expect(cache.get("channel-three", start + 301.seconds)).not_to be_nil
  end

  it "does not let caller changes mutate the shared cached page" do
    cache = LightiousChannelFeed::RecentCache.new
    start = Time.instant
    page = [ChannelFeedSpecHelpers.entry("one", 100)]
    cache.put("channel", page, start)
    page.clear
    cached = cache.get("channel", start + 1.second).not_nil!
    cached.clear
    expect(cache.get("channel", start + 2.seconds).not_nil!.map(&.id)).to eq(["one"])
  end

  it "disables cursor sources when the channel no longer exposes their tabs" do
    cursor = described_class.initial_cursor(true, true)
    constrained = described_class.constrain(cursor, true, false)

    expect(constrained.uploads.complete).to be_false
    expect(constrained.streams.complete).to be_true
  end
end

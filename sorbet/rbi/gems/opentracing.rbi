# This file is autogenerated. Do not edit it by hand. Regenerate it with:
#   srb rbi gems

# typed: strict
#
# If you would like to make changes to this file, great! Please create the gem's shim here:
#
#   https://github.com/sorbet/sorbet-typed/new/master?filename=lib/opentracing/all/opentracing.rbi
#
# opentracing-0.5.0

module OpenTracing
  def self.active_span(*args, &block); end
  def self.extract(*args, &block); end
  def self.global_tracer; end
  def self.global_tracer=(tracer); end
  def self.inject(*args, &block); end
  def self.scope_manager(*args, &block); end
  def self.start_active_span(*args, &block); end
  def self.start_span(*args, &block); end
end
class OpenTracing::SpanContext
  def baggage; end
  def initialize(baggage: nil); end
end
class OpenTracing::Span
  def context; end
  def finish(end_time: nil); end
  def get_baggage_item(key); end
  def log(event: nil, timestamp: nil, **fields); end
  def log_kv(timestamp: nil, **fields); end
  def operation_name=(name); end
  def set_baggage_item(key, value); end
  def set_tag(key, value); end
end
class OpenTracing::Reference
  def context; end
  def initialize(type, context); end
  def self.child_of(context); end
  def self.follows_from(context); end
  def type; end
end
class OpenTracing::Tracer
  def active_span; end
  def extract(format, carrier); end
  def inject(span_context, format, carrier); end
  def scope_manager; end
  def start_active_span(operation_name, child_of: nil, references: nil, start_time: nil, tags: nil, ignore_active_scope: nil, finish_on_close: nil); end
  def start_span(operation_name, child_of: nil, references: nil, start_time: nil, tags: nil, ignore_active_scope: nil); end
end
class OpenTracing::Scope
  def close; end
  def span; end
end
class OpenTracing::ScopeManager
  def activate(span, finish_on_close: nil); end
  def active; end
end
class OpenTracing::Carrier
  def [](key); end
  def []=(key, value); end
  def each(&block); end
end
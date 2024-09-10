require "openai"
require "chroma-db"
require "securerandom"
require "linenoise"

require "async"
require "async/barrier"
require "async/semaphore"

Chroma.connect_host = "http://localhost:8000"
Chroma.logger       = Logger.new($stdout)
Chroma.log_level    = Chroma::LEVEL_ERROR

OpenAI.configure do |config|
  config.access_token = ENV.fetch("OPENAI_AUTH_KEY")
  config.log_errors   = true
end

class FactDB

  def initialize(name, metadata=nil)
    @openai     = OpenAI::Client.new
    @collection = Chroma::Resources::Collection.get_or_create(name, metadata)
  end

  def insert(subject, fact)
    embedding = fetch_embedding(fact)
    embedding = Chroma::Resources::Embedding.new(
      id: SecureRandom.uuid,
      metadata: { subject: subject.downcase.strip, fact: },
      embedding:
    )

    @collection.add(embedding)
  end

  def search(subject, query)
    where = { subject: subject.downcase.strip }

    if query.nil? || query.downcase.strip == 'everything'
      @collection.get(where:)
    else
      embedding = fetch_embedding(query)
      @collection.query(query_embeddings: [embedding], where:)
    end
  end

  private

  def fetch_embedding(text)
    resp = @openai.embeddings(
      parameters: {
        model: "text-embedding-ada-002",
        input: text
      }
    )

    resp.dig("data", 0, "embedding")
  end

end

class Assistant

  def initialize(id:, thread_id: nil, &block)
    @openai = OpenAI::Client.new

    @assistant_id = id
    @thread_id    = thread_id || @openai.threads.create()&.[]("id")
    @tools        = Class.new(&block).new
  end

  def messages
    @openai.messages.list(thread_id: @thread_id)
  end

  def msg_as_assistant(content)
    @openai.messages.create(thread_id: @thread_id, parameters: { role: 'assistant', content: })
  end

  def msg_as_user(content)
    @openai.messages.create(thread_id: @thread_id, parameters: { role: 'user', content: })
  end

  def msg_tool_response(run_id:, tool_call_id:, output:)
    @openai.runs.submit_tool_outputs(
      run_id:,
      thread_id: @thread_id,
      parameters: {
        tool_outputs: [{ tool_call_id:, output: JSON.generate(output) }]
      }
    )
  end

  def dispatch_tool(name:, arguments:, **)
    m = @tools.method(name.to_sym)
    raise ArgumentError, "name is not a known function: #{name}" if m.nil?

    a = arguments.transform_keys(&:to_sym)
    m.call(**a)
  rescue => ex
    $stderr.puts "error: #{ex}"
    { success: false, error: ex.to_s }
  end

  def execute_run(parent: Async::Task.current)
    run_id = @openai.runs.create(thread_id: @thread_id, parameters: { assistant_id: @assistant_id })&.[]("id")

    parent.async do |task|
      loop do
        response = @openai.runs.retrieve(id: run_id, thread_id: @thread_id)
        status   = response['status']

        case status
        when 'queued', 'in_progress', 'cancelling'
          puts 'waiting...'
          sleep 1

        when 'requires_action'
          run_id    = response["id"]
          req_calls = response.dig("required_action", "submit_tool_outputs", "tool_calls")

          semaphore = Async::Semaphore.new(5, parent: task)
          outputs   = req_calls.map do |call|
            semaphore.async do
              tool_call_id = call["id"]
              name         = call.dig("function", "name")
              arguments    = JSON.parse(call.dig("function", "arguments"))

              puts "making asynchronous tool call... \n\t#{tool_call_id} #{name} #{arguments}"
              { tool_call_id:, output: dispatch_tool(name:, arguments:) }
            end
          end.map(&:wait)

          puts "submitting tool response"
          @openai.runs.submit_tool_outputs(
            run_id:,
            thread_id: @thread_id,
            parameters: {
              tool_outputs: outputs.map { |out| { tool_call_id: out[:tool_call_id], output: JSON.generate(out[:output]) } }
            }
          )

        when 'complete', 'completed'
          puts 'complete'
          break response

        when 'cancelled', 'failed', 'expired'
          puts response['last_error'].inspect
          break response

        else
          puts "unknown status #{status}"

        end
      end
    end
  end
end

Sync do
  @a = Assistant.new(id: "asst_OhUrhiPX0WAqxbB76Jx7bGqo") do
    def initialize
      @f = FactDB.new("asst-facts")
    end

    def remember_fact(subject:, fact:)
      @f.insert(subject, fact)
      puts "remember complete..."
      { success: true }
    end

    def recall_fact(subject:, query:)
      output = @f.search(subject, query)
      puts "recall complete... #{output.map(&:metadata)}"
      output.map(&:metadata)
    end
  end

  @a.msg_as_assistant("the current date and time is #{DateTime.now.iso8601}.")
  @a.msg_as_assistant("I have to make sure I use my tools to remember things; this is not the first chat we've had.")

  while input = Linenoise.linenoise('> ')
    @a.msg_as_user input
    @a.execute_run.wait

    msg = @a.messages()["data"].first
    msg.dig("content").each do |msg|
      msg = msg.dig("text", "value")
      puts "🤖 #{msg}"
    end

    puts " "
  end
end

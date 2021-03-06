class RedisQueue
  DEFAULT_QUEUE_NAME = ENV['REDIS_QUEUE_NAME']

  def initialize(repos = nil, queue_name: nil, enqueue: false)
    @redis = RedisWrapper.new.redis

    if queue_name
      @queue_name = queue_name
    else
      @queue_name = self.class::DEFAULT_QUEUE_NAME
    end

    @repos = repos # Only needed for enqueing

    enqueue_redis if enqueue
  end

  def enqueue_redis
    clear_queue
    # Insert into redis. The left side of the queue is the high side
    @redis.pipelined do
      @repos.each do |repo|
        # Must be a string
        member = {
          name: repo.name,
          id: repo.id,
          url: repo.url,
        }.to_json

        # Use the priority value as the initial score
        add(member)
      end
      puts "#{@repos.count} repos enqueued"
    end
  end

  def next
    next_repo = @redis.lpop @queue_name
    JSON.parse(next_repo)
  end

  private

  def clear_queue
    @redis.del(@queue_name)
  end

  def add(member)
    @redis.rpush @queue_name, member
  end
end

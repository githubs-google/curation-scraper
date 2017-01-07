class GithubSearchWrapper
  @BASE_URL = 'https://api.github.com/search/repositories'
  @access_token = ENV["GITHUB_API_KEY"]
  @repos_processed = 0

  class << self
    def paginate_repos
      # Set initial kickoff url to paginate from
      @start_time = Time.now
      handle_first_round_of_pagination
      loop do
        loop do
          @resp = search_request
          puts "Search request to #{@current_url}"

          rate_requests_remain? ? handle_request : break
        end

        wait_time = Time.at(seconds_to_reset) - Time.now

        if abuse_error?
          puts "Sleeping due to abuse error"
          sleep @resp.headers['retry-after'].to_i
          next
        end

        puts "Time until reset: #{Time.at(seconds_to_reset)}"
        puts "Current time: #{Time.now.to_s}"

        puts "Out of requests... Sleeping ~#{wait_time} s"

        sleep wait_time unless wait_time.negative?
      end
    end

    private

    def handle_first_round_of_pagination
      @current_url = @BASE_URL + "?q=stars:>1&sort=stars&order=desc"
      loop do
        @resp = search_request
        @parsed_repos = JSON.parse(@resp.body)['items']

        puts "Request: #{@current_url}"

        process_repos

        if last_pagination?
          @star_count = @parsed_repos.last['stargazers_count'].to_i
          @current_url = @BASE_URL + "?q=stars:#{@star_count}"
          break
        else
          @current_url = @resp.headers['link'].split(',').first.split(';').first[/(?<=<).*(?=>)/]
        end
      end
    end

    def handle_request
      @parsed_repos = JSON.parse(@resp.body)['items']
      if no_repos_for_star_count?
        @current_url = @BASE_URL + "?q=stars:#{@star_count -= 1}"
        return
      end
      @first_repo_stars_of_first_pagination = @parsed_repos.first['stargazers_count'] if first_pagination?

      puts "Request: #{@current_url}"

      process_repos

      if repeat_pagination?
        puts "Aborting due to repeating loop"
        abort
      elsif last_pagination?
        @current_url = @BASE_URL + "?q=stars:#{@star_count -= 1}"
      else
        @current_url = @resp.headers['link'].split(',').first.split(';').first[/(?<=<).*(?=>)/]
      end
    end

    def first_round_of_pagination?
      @star_count.nil?
    end

    def no_repos_for_star_count?
      @parsed_repos.empty?
    end

    def first_pagination?
      @resp.headers['link'] && !@resp.headers['link'].include?('rel="first"')
    end

    def repeat_pagination?
      last_pagination? && first_and_last_repo_star_count_equal?
    end

    def last_pagination?
      @resp.headers['link'] && !@resp.headers['link'].include?('rel="last"') || !@resp.headers['link']
    end

    def first_and_last_repo_star_count_equal?
      @parsed_repos.last['stargazers_count'] == @first_repo_stars_of_first_pagination
    end

    def process_repos
      puts "Processing #{@parsed_repos.count} Repositories."
      repos = @parsed_repos.map do |repo|
        Repository.new({
          name: repo['name'],
          github_id: repo['id'],
          url: repo['html_url'],
          language: repo['language'],
          stars:  repo['stargazers_count'],
          forks:  repo['forks']
        })
      end
      Repository.import(repos)
      puts "#{@repos_processed += @parsed_repos.count} Repositories Processed in #{minutes_running} minutes."
    end

    def minutes_running
      ((Time.now - @start_time) / 60).round(2)
    end

    def search_request
      Faraday.get(@current_url) do |req|
        req.headers['Authorization'] = "token #{@access_token}"
        req.headers['Accept'] = 'application/vnd.github.v3+json'
      end
    end

    def rate_requests_remain?
      requests_remaining > 0
    end

    def requests_remaining
      @resp.headers['x-ratelimit-remaining'].to_i
    end

    def seconds_to_reset
      @resp.headers['x-ratelimit-reset'].to_i
    end

    def abuse_error?
      seconds_to_reset == 0
    end
  end
end

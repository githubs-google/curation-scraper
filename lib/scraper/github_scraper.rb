require 'nokogiri'
require 'open-uri'
require 'httplog'

# Scrapes data for Gems and Users on Github.com
class GithubScraper
  @github_doc = nil
  @current_lib = nil
  @HEADERS_HASH = {"User-Agent" => "Ruby"}
  @SECONDS_BETWEEN_REQUESTS = 0

  class << self
    attr_reader :github_doc
    # Gets the following:
    # - number of stars the project has
    # - raw README.md file
    #
    # Example project's Github url vs raw url
    # - Github: https://github.com/rspec/rspec/blob/master/README.md
    # - Raw: https://raw.githubusercontent.com/rspec/rspec/master/README.md
    #
    # gems: gems whose repo data will be updated
    def update_gem_data(gems = RubyGem.all)
      gems.each do |gem|
        begin
          @current_lib = gem
          @github_doc = Nokogiri::HTML(open(@current_lib.url, @HEADERS_HASH))
          puts "Updated gem #{@current_lib.name}"

          # TODO: add to update_gem_data to get repo name and owner name
          # owner, repo_name = @current_lib.url[/\/\w+\/\w+/].split('/)

          # Parse the page and update gem
          gem.update(stars: repo_stars, description: repo_description)
        rescue OpenURI::HTTPError => e
          gem.destroy
          puts "DESTROYED Gem #{@current_lib.name} : its Github URL #{@current_lib.url} resulted in #{e.message}"
        end
      end
    end

    # Retrieves the commits for each RubyGem
    #
    # NOTE: you can use all options together, but whichever one ends first
    #       will be the one that stops the scraper
    #
    # Options
    # libraries: libraries whose repos will be scraped for data
    # page_limit: maximum number of pages to iterate
    # user_limit: max number of users to add
    # TODO: expand rake task to pass in these options
    def lib_commits(scrape_limit_opts={})
      handle_scrape_limits(scrape_limit_opts)
      catch :scrape_limit_reached do
        @libraries.each do |lib|
          @current_lib = lib
          commits_path = @current_lib.url + '/commits/master'

          puts "Scraping #{lib.name} commits"

          @github_doc = commits_path
          if @github_doc
          tries = 3
          begin
            @github_doc = Nokogiri::HTML(open(commits_path, @HEADERS_HASH))
          rescue Timeout::Error => e
            tries -= 1
            if tries > 0
              retry
            else
              puts e.message
            end
          end

          catch :recent_commits_finished do
            traverse_commit_pagination
          end
          @page_limit
        end
      end
    end

    def create_github_doc(url = nil)
      tries ||= 3
      @github_doc = Nokogiri::HTML(open(url, @HEADERS_HASH))
    rescue Timeout::Error => e
      tries -= 1
      if tries > 0
        retry
      else
        puts e.message
      end
    end

    # 2 agents for user data and stars/followers data
    def update_user_data
      User.all.each do |user|
        @github_doc = Nokogiri::HTML(open("https://github.com/#{user.github_username}"))
        followers = @github_doc.css('a[href="/#{user.github_username}?tab=followers .counter"]').text.strip
        name = @github_doc.css('.vcard-fullname').text.strip

        personal_repos_doc = Nokogiri::HTML(open("https://github.com/#{user.github_username}?page=1&tab=repositories", @HEADERS_HASH))
        personal_star_count = 0
        pagination_count = 1

        loop do
          personal_repos_doc.css('a[aria-label="Stargazers"]').each do |star_count|
            personal_star_count += star_count.text.strip.to_i
          end

          break if personal_repos_doc.css('.next_page.disabled').any?

          pagination_count += 1
          page_regex = /page=#{pagination_count}/

          personal_repos_doc = Nokogiri::HTML(open("https://github.com/#{user.github_username}?page=1&tab=repositories".gsub(/page=\d/, "page=#{pagination_count}", @HEADERS_HASH)))
        end

        User.update(user.id,
                    name: name,
                    followers: followers,
                    stars: personal_star_count)
      end
    end

    private

    def open_html_doc(url)
    end

    # Avoid looking too robotic to Github
    def random_sleep
      sleep [3].sample
    end

    # this can be added to the other scraper
    def handle_scrape_limits(opts={})
      @libraries = opts[:libraries] || RubyGem.all
      @page_limit = opts[:page_limit] || Float::INFINITY
      @user_limit = opts[:user_limit] || Float::INFINITY
    end

    def traverse_commit_pagination
      page_count = 1
      loop do
        fetch_commit_data

        throw :scrape_limit_reached if page_count >= @page_limit
        break unless @github_doc.css('.pagination').any?
        page_count += 1

        next_path = @github_doc.css('.pagination a')[0]['href']

        sleep SECONDS_BETWEEN_REQUESTS

        @github_doc = Nokogiri::HTML(open('https://github.com' + next_path, @HEADERS_HASH))
      end
    end

    def fetch_commit_data
      @github_doc.css('.commit').each do |commit_info|
        commit_date = Time.parse(commit_info.css('relative-time')[0][:datetime])
        throw :recent_commits_finished unless commit_date.today?

        # Not all avatars are users
        user_anchor = commit_info.css('.commit-avatar-cell a')[0]
        github_username = user_anchor['href'][1..-1] if user_anchor

        if !github_username.nil? && !User.exists?(github_username: github_username)
          user = User.create(github_username: github_username)
          puts "User CREATE github_username:#{user.github_username}"
        elsif !github_username.nil?
          user = User.find_by(github_username: github_username)
        end

        if user
          message = commit_info.css("a.message").text
          github_identifier = commit_info.css("a.sha").text.strip

          unless Commit.exists?(github_identifier: github_identifier)
            # TODO: migration for gem_id fk
            Commit.create(
              message: message,
              user: user,
              ruby_gem: @current_lib,
              github_identifier: github_identifier
              )
            puts "Commit CREATE identifier:#{github_identifier} by #{user.github_username}"
          end
        end

        throw :scrape_limit_reached if User.count >= @user_limit
      end
    end

    def repo_description
      if @github_doc.at('td span:contains("README")')
        raw_file_url = @current_lib.url.gsub('github', 'raw.githubusercontent') \
                          + '/master/README.md'
        Nokogiri::HTML(open(raw_file_url, @HEADERS_HASH)).css('body p').text
      else
        "Empty"
      end
    end

    def repo_stars
      @github_doc.css('ul.pagehead-actions li:nth-child(2) .social-count')
        .text.strip.gsub(',', '').to_i
    end
  end
end

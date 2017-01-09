# TODO: There eventually needs to be a callback here to add a Repository to the
#       Redis queue on creation
class Repository < ActiveRecord::Base
  validates :github_id, uniqueness: true

  has_many :commits
  has_many :issues

  def update_score
    update(score: score)
  end

  def score
    activity_score + significance_score
  end

  private

  def activity_score
    # TODO: We should only get the commits for a given time period, when calculating
    # this, not all the commits on a repository
    commits.count + issues.issues_comments.count + open_issues
  end

  def significance_score
    # convert any nil values to zero with to_i
    stars.to_i + forks.to_i + watchers.to_i
  end
end
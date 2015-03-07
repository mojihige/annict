# == Schema Information
#
# Table name: checks
#
#  id                  :integer          not null, primary key
#  user_id             :integer          not null
#  work_id             :integer          not null
#  episode_id          :integer
#  skipped_episode_ids :integer          default("{}"), not null, is an Array
#  position            :integer          default("0"), not null
#  created_at          :datetime         not null
#  updated_at          :datetime         not null
#
# Indexes
#
#  index_checks_on_user_id               (user_id)
#  index_checks_on_user_id_and_position  (user_id,position)
#  index_checks_on_user_id_and_work_id   (user_id,work_id) UNIQUE
#

class Check < ActiveRecord::Base
  acts_as_list scope: :user

  belongs_to :user
  belongs_to :work
  belongs_to :episode

  scope :has_episode, -> { where.not(episode_id: nil) }


  def self.refresh_episode(user)
    checks = user.checks.includes(:work).where(episode_id: nil)

    checks.each do |check|
      if user.statuses.kind_of(check.work).try(:kind) != 'on_hold'
        check.update_episode_to_unchecked
      end
    end
  end

  # チェックインしていないエピソードに設定する
  def update_episode_to_unchecked
    unchecked_episode = user.episodes.unchecked(work)
      .where.not(id: skipped_episode_ids).order(sort_number: :asc).first

    if unchecked_episode.present?
      update_column(:episode_id, unchecked_episode.id)
    elsif work.on_air?
      # 放送中のアニメの場合はまだ最新エピソードが登録される可能性があるので、
      # nilを設定しておく
      update_column(:episode_id, nil)
    else
      update_episode_to_first
    end
  end

  def update_episode_to_next(options = {})
    model = options[:checkin].presence || self
    next_episode = model.episode.try(:next_episode)

    if next_episode.present?
      update_column(:episode_id, next_episode.id)
      move_to_top
    else
      update_column(:episode_id, nil)
    end
  end

  def update_episode_to_first
    first_episode = work.episodes.order(sort_number: :asc).first

    update_column(:episode_id, first_episode.id) if first_episode.present?
  end

  def skip_episode
    if episode.present?
      skipped_episode_ids << episode.id
      save
      update_episode_to_next
    end
  end
end

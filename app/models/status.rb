# == Schema Information
#
# Table name: statuses
#
#  id          :integer          not null, primary key
#  user_id     :integer          not null
#  work_id     :integer          not null
#  kind        :integer          not null
#  latest      :boolean          default("false"), not null
#  likes_count :integer          default("0"), not null
#  created_at  :datetime
#  updated_at  :datetime
#
# Indexes
#
#  statuses_user_id_idx  (user_id)
#  statuses_work_id_idx  (work_id)
#

class Status < ActiveRecord::Base
  extend Enumerize

  enumerize :kind, in: { wanna_watch: 1, watching: 2, watched: 3, on_hold: 5, stop_watching: 4 }, scope: true

  belongs_to :user
  belongs_to :work

  scope :latest, -> { where(latest: true) }
  scope :watching, -> { latest.with_kind(:watching) }
  scope :wanna_watch, -> { latest.with_kind(:wanna_watch) }
  scope :wanna_watch_and_watching, -> { latest.with_kind(:wanna_watch, :watching) }
  scope :desiring_to_watch, -> { latest.with_kind(:wanna_watch, :watching, :on_hold) }
  scope :on_hold, -> { latest.with_kind(:on_hold) }

  after_create :change_latest
  after_create :save_activity
  after_create :refresh_watchers_count
  after_create :update_recommendable
  after_create :update_channel_work
  after_create :finish_tips
  after_create :refresh_check
  after_commit :publish_events, on: :create


  def self.initial
    order(:id).first
  end

  def self.initial?(status)
    count == 1 && initial.id == status.id
  end

  def self.kind_of(work)
    latest.find_by(work_id: work.id)
  end

  private

  def change_latest
    latest_status = user.statuses.find_by(work_id: work.id, latest: true)
    latest_status.update_column(:latest, false) if latest_status.present?

    update_column(:latest, true)
  end

  def save_activity
    Activity.create do |a|
      a.user      = user
      a.recipient = work
      a.trackable = self
      a.action    = 'statuses.create'
    end
  end

  def refresh_watchers_count
    if become_to == :watch
      work.increment!(:watchers_count)
    elsif become_to == :drop
      work.decrement!(:watchers_count)
    end
  end

  # ステータスを何から何に変えたかを返す
  def become_to
    watches  = [:wanna_watch, :watching, :watched]
    statuses = user.statuses.where(work_id: work.id).includes(:work).last(2)
    prev_status = statuses.first.kind.to_sym
    new_status  = statuses.last.kind.to_sym

    if statuses.length == 2
      return :watch if !watches.include?(prev_status) && watches.include?(new_status)
      return :drop  if watches.include?(prev_status)  && !watches.include?(new_status)
      return :keep # 見たい系 -> 見たい系 または 中止系 -> 中止系
    end

    watches.include?(new_status) ? :watch : :drop_first
  end

  # ステータスの変更があったとき、「Recommendable」の `like`, `dislike` などを呼び出して
  # オススメ作品を更新する
  def update_recommendable
    case become_to
    when :watch
      user.undislike(work) if user.dislikes?(work)
      user.like(work)
    when :drop
      user.unlike(work) if user.likes?(work)
      user.dislike(work)
    when :drop_first
      user.dislike(work)
    end
  end

  def update_channel_work
    case kind
    when 'wanna_watch', 'watching'
      ChannelWorkService.new(user).create(work)
    else
      ChannelWorkService.new(user).delete(work)
    end
  end


  private

  def publish_events
    FirstStatusesEvent.publish(:create, self) if user.statuses.initial?(self)
    StatusesEvent.publish(:create, self)
  end

  def finish_tips
    if user.statuses.initial?(self)
      UserTipsService.new(user).finish!(:status)
    end
  end

  def refresh_check
    is_watch_status      = %w(wanna_watch watching).include?(kind.to_s)
    is_on_hold_status    = %w(on_hold).include?(kind.to_s)
    is_watch_over_status = %w(watched stop_watching).include?(kind.to_s)

    check = user.checks.find_by(work_id: work.id)

    # 初めてそのアニメを「見てる」などにしたとき
    if check.blank? && is_watch_status
      check = user.checks.create(work: work)
      check.update_episode_to_first
    # 「見たい」状態の新作アニメを「見てる」に変えたときなど
    elsif check.present? && is_watch_status && check.episode.blank?
      check.update_episode_to_unchecked
    elsif check.present? && is_on_hold_status
      check.update_column(:episode_id, nil)
    elsif check.present? && is_watch_over_status
      check.destroy
    end
  end
end

#   Copyright (c) 2009, Diaspora Inc.  This file is
#   licensed under the Affero General Public License version 3 or later.  See
#   the COPYRIGHT file.

class Photo < ActiveRecord::Base
  require 'carrierwave/orm/activerecord'

  include Diaspora::Commentable
  include Diaspora::Shareable

  mount_uploader :processed_image, ProcessedImage
  mount_uploader :unprocessed_image, UnprocessedImage

  xml_attr :remote_photo_path
  xml_attr :remote_photo_name

  xml_attr :text
  xml_attr :status_message_guid

  belongs_to :status_message, :foreign_key => :status_message_guid, :primary_key => :guid

  attr_accessible :text, :pending
  validate :ownership_of_status_message

  before_destroy :ensure_user_picture
  after_destroy :clear_empty_status_message
  after_create :queue_processing_job

  def clear_empty_status_message
    if self.status_message_guid && self.status_message.text_and_photos_blank?
      self.status_message.destroy
    else
      true
    end
  end

  def ownership_of_status_message
    message = StatusMessage.find_by_guid(self.status_message_guid)
    if self.status_message_guid && message
      self.diaspora_handle == message.diaspora_handle
    else
      true
    end
  end

  def self.diaspora_initialize(params = {})
    photo = self.new params.to_hash
    photo.author = params[:author]
    photo.public = params[:public] if params[:public]
    photo.pending = params[:pending] if params[:pending]
    photo.diaspora_handle = photo.author.diaspora_handle

    image_file = params.delete(:user_file)
    photo.random_string = ActiveSupport::SecureRandom.hex(10)
    photo.unprocessed_image.store! image_file
    photo.update_remote_path
    photo
  end

  def processed?
    processed_image.path.present?
  end

  def update_remote_path
    unless self.unprocessed_image.url.match(/^https?:\/\//)
      pod_url = AppConfig[:pod_url].dup
      pod_url.chop! if AppConfig[:pod_url][-1,1] == '/'
      remote_path = "#{pod_url}#{self.unprocessed_image.url}"
    else
      remote_path = self.unprocessed_image.url
    end

    name_start = remote_path.rindex '/'
    self.remote_photo_path = "#{remote_path.slice(0, name_start)}/"
    self.remote_photo_name = remote_path.slice(name_start + 1, remote_path.length)
  end

  def url(name = nil)
    if remote_photo_path
      name = name.to_s + '_' if name
      remote_photo_path + name.to_s + remote_photo_name
    elsif processed?
      processed_image.url(name)
    else
      unprocessed_image.url(name)
    end
  end

  def ensure_user_picture
    profiles = Profile.where(:image_url => url(:thumb_large))
    profiles.each { |profile|
      profile.image_url = nil
      profile.save
    }
  end

  def thumb_hash
    {:thumb_url => url(:thumb_medium), :id => id, :album_id => nil}
  end

  def queue_processing_job
    Resque.enqueue(Jobs::ProcessPhoto, self.id)
  end

  def mutable?
    true
  end

  scope :on_statuses, lambda { |post_guids|
    where(:status_message_guid => post_guids)
  }
end

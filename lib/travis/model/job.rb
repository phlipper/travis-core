require 'active_record'

# Job models a unit of work that is run on a remote worker.
#
# There currently only one job type:
#
#  * Job::Test belongs to a Build (one or many Job::Test instances make up a
#    build matrix) and executes a test suite with parameters defined in the
#    configuration.
class Job < ActiveRecord::Base
  autoload :Compat,    'travis/model/job/compat'
  autoload :Cleanup,   'travis/model/job/cleanup'
  autoload :Limit,     'travis/model/job/limit'
  autoload :Queue,     'travis/model/job/queue'
  autoload :Queueing,  'travis/model/job/queueing'
  autoload :States,    'travis/model/job/states'
  autoload :Sponsors,  'travis/model/job/sponsors'
  autoload :Tagging,   'travis/model/job/tagging'
  autoload :Test,      'travis/model/job/test'

  class << self
    # what we return from the json api
    def queued(queue = nil)
      scope = where(:state => [:created, :queued])
      scope = scope.where(:queue => queue) if queue
      scope
    end

    # what needs to be queued up
    def queueable(queue = nil)
      scope = where(:state => :created).order('id DESC')
      scope = scope.where(:queue => queue) if queue
      scope
    end

    # what already is queued or started
    def running(queue = nil)
      scope = where(:state => [:queued, :started])
      scope = scope.where(:queue => queue) if queue
      scope
    end

    def owned_by(owner)
      where(:owner_id => owner.id, :owner_type => owner.class.to_s)
    end
  end

  include Cleanup, Compat
  include Travis::Model::EnvHelpers

  has_one    :log, :class_name => 'Artifact::Log', :conditions => { :type => 'Artifact::Log' }, :dependent => :destroy
  has_many   :artifacts
  belongs_to :repository
  belongs_to :commit
  belongs_to :source, :polymorphic => true, :autosave => true
  belongs_to :owner, :polymorphic => true

  validates :repository_id, :commit_id, :source_id, :source_type, :owner_id, :owner_type, :presence => true

  serialize :config

  delegate :request_id, :to => :source # TODO denormalize
  delegate :pull_request?, :to => :commit

  after_initialize do
    self.config = {} if config.nil?
  end

  before_create do
    build_log
    self.state = :created if self.state.nil?
    self.queue = Queue.for(self).name
  end

  def duration
    started_at && finished_at ? finished_at - started_at : nil
  end

  def config=(config)
    super(config ? config.deep_symbolize_keys : {})
  end

  def obfuscated_config
    self.config.dup.tap do |config|
      if config[:env]
        config[:env] = process_env_vars(config[:env]) do |env|
          obfuscate_env_vars(env)
        end.join(' ')
      end
    end
  end

  def decrypted_config
    self.config.dup.tap do |config|
      if config[:env]
        config[:env] = process_env_vars(config[:env]) do |env|
          decrypt_env_vars(env) rescue {}
        end
      end
    end
  end

  def matrix_config?(config)
    config = config.to_hash.symbolize_keys
    Build.matrix_keys_for(config).map do |key|
      self.config[key.to_sym] == config[key] || commit.branch == config[key]
    end.inject(:&)
  end

  private

    def process_env_vars(env)
      env = [env] unless env.is_a? Array

      env = if pull_request?
        remove_encrypted_env_vars(env)
      else
        yield(env)
      end

      env.compact.presence
    end

    def remove_encrypted_env_vars(env)
      env.reject do |var|
        var.is_a?(Hash) && var.has_key?(:secure)
      end
    end

    def decrypt_env_vars(env)
      env.map do |var|
        decrypt(var) do |var|
          var.insert(0, 'SECURE ') unless var.include?('SECURE ')
        end
      end
    end

    def decrypt(v, &block)
      repository.key.secure.decrypt(v, &block)
    end
end

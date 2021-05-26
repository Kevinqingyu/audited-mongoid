#encoding: utf-8
# 使用方法
# class Model < ActiveRecord::Base
#   MONGO_EXPIRE_AFTER_SECONDS = 30.days # mongo中日志保留时间
#   include Audited # 引入审计模块
#   audited  # 调用审计初始化方法
# end

# audited 方法使用
# 监控所有字段(不包含默认忽略字段， 例如：created_at updated_at...)
# audited

# 监控单一字段
# audited only: :name

# 监控多个字段
# audited only: [:name, :address]

# 除某些字段外的所有字段
# audited except: :password

module Audited
  module DeepLocate
    def self.deep_locate(comparator, object)
      comparator = _construct_key_comparator(comparator, object) unless comparator.respond_to?(:call)

      _deep_locate(comparator, object)
    end

    def deep_locate(comparator)
      DeepLocate.deep_locate(comparator, self)
    end

    private

    def self._construct_key_comparator(search_key, object)
      search_key = search_key.to_s if defined?(::ActiveSupport::HashWithIndifferentAccess) && object.is_a?(::ActiveSupport::HashWithIndifferentAccess)
      search_key = search_key.to_s if object.respond_to?(:indifferent_access?) && object.indifferent_access?

      lambda do |non_callable_object|
        ->(key, _, _) { key == non_callable_object }
      end.call(search_key)
    end

    def self._deep_locate(comparator, object, result = [])
      if object.is_a?(::Enumerable)
        if object.any? { |value| _match_comparator?(value, comparator, object) }
          result.push object
        end
        (object.respond_to?(:values) ? object.values : object.entries).each do |value|
          _deep_locate(comparator, value, result)
        end
      end

      result
    end

    def self._match_comparator?(value, comparator, object)
      if object.is_a?(::Hash)
        key, value = value
      else
        key = nil
      end

      comparator.call(key, value, object)
    end
  end

  module AuditCore
    MONGO_EXPIRE_AFTER_SECONDS = 90.days
    class << self
      def included(base)
        base.extend ClassMethods
      end
    end
    module ClassMethods
      def init_mongodb(options = {})
        if options[:expire_after_seconds].blank?
          options[:expire_after_seconds] = AuditCore::MONGO_EXPIRE_AFTER_SECONDS
        end
        include ::Mongoid::Document
        include ::Mongoid::Timestamps

        field :auditable_id   , type: Integer              # 对象ID
        field :auditable_type , type: String               # 对象模型
        field :associated_id  , type: Integer              # 关联ID
        field :associated_type, type: String               # 关联模型
        field :operator_id    , type: Integer              # 操作人ID
        field :operator_type  , type: String               # 操作人类型
        field :controller     , type: String               # 控制器
        field :action         , type: String               # 行动
        field :event          , type: String               # 事件
        field :params         , type: Hash                 # 参数
        field :audited_changes, type: Hash                 # 变更内容
        field :version        , type: Integer, default: 0  # 版本
        field :remote_address , type: String               # 远端地址
        field :request_uuid   , type: String               # 请求UUID

        index({ auditable_id: 1, auditable_type: 1, version: 1 }, { name: "auditable_version_index", background: true })
        index({ associated_id: 1, associated_type: 1 }, { name: "associated_index", background: true })
        index({ operator_id: 1, operator_type: 1 }, { name: "operator_index", background: true })
        index({ created_at: 1}, { name: "created_at_index", background: true, expire_after_seconds: options[:expire_after_seconds]})

        before_create :set_version_number, :set_request, :set_operator

        define_method(:sanitize_for_time_with_zone) do |value|
          case value
          when Hash
            value.inject({}){|h,(k,v)| h[k] = sanitize_for_time_with_zone(v); h }
          when Array
            value.map{|v| sanitize_for_time_with_zone(v) }
          when ActiveSupport::TimeWithZone
            value.utc
          else
            value
          end
        end
      end
    end

    def audited_changes=(value)
      self[:audited_changes] = self.class.sanitize_for_time_with_zone(value)
    end

    def ancestors
      self.class.where(:auditable_id => auditable_id, :auditable_type => auditable_type, :version.lte => version)
    end

    private
    def set_version_number
      max = self.class.where(
        :auditable_id => auditable_id,
        :auditable_type => auditable_type
      ).order(:version.desc).first.try(:version) || 0
      self.version = max + 1
    end

    # 设置操作人
    def set_operator
      self.operator_id = Thread.current[:operator_id]
      self.operator_type = Thread.current[:operator_type]
    end

    # 设置请求信息
    def set_request
      if controller_request
        self.request_uuid   ||= controller_request.uuid
        self.remote_address ||= controller_request.remote_ip
        self.action         ||= controller_request.params["action"]
        self.controller     ||= controller_request.params["controller"]
      end
    end

    # 清理file文件
    def remove_file_from_raw_request(checking_params)
      checking_params = checking_params.extend(DeepLocate)
      checking_params.deep_locate -> (key, value, object) do
        if value.class.name.include?('UploadedFile') && value.respond_to?('path')
          if object.is_a?(Array)
            key = object.index(value)
            object[key] = Digest::SHA256.file(value.path).hexdigest
          else
            object[key] = Digest::SHA256.file(value.path).hexdigest
          end
        end
      end
      checking_params
    end

    def raw_request_params
      controller_request.POST.deep_dup.merge(controller_request.GET.deep_dup)
    end

    def controller_request
      Util.thread_cached_params["controller_request"]
    end
  end

  PARAMS        = 'params'
  OPERATOR_ID   = 'operator_id'
  OPERATOR_TYPE = 'operator_type'

  class << self
    attr_accessor :ignored_attributes
    def included(base)
      base.extend ClassMethods
    end

    def get_class(clazz)
      clazz.audit_clazz
    end
  end

  @ignored_attributes = %w(lock_version created_at updated_at created_on updated_on)

  module ClassMethods
    def audited(options = {})
      clazz_name = "#{self.name}AuditLog"
      cattr_accessor :audit_clazz
      class_attribute :non_audited_columns,   :instance_writer => false
      class_attribute :audit_associated_with, :instance_writer => false
      klass = Object.const_set(clazz_name, Class.new(AbstractMongodbClass))
      klass.include(AuditCore)
      klass.init_mongodb({expire_after_seconds: options[:expire_after_seconds]})
      klass.store_in collection: clazz_name.underscore.pluralize
      self.audit_clazz = klass

      if options[:only]
        except = self.column_names - Array(options[:only]).flatten.map(&:to_s)
      else
        except = audit_default_ignored_attributes + Audited.ignored_attributes
        except |= Array(options[:except]).collect(&:to_s) if options[:except]
      end
      self.non_audited_columns = except

      after_create  :audit_create
      before_update :audit_update
      before_destroy :audit_destroy
    end

    def audit_default_ignored_attributes
      ['id', '_id']
    end
  end

  def audits
    return [] if self.audit_clazz.blank?
    self.audit_clazz.where(auditable_id: self.id, auditable_type: self.class.to_s).order(version: :desc)
  end

  private

    def audited_changes
      changed_attributes.except(*non_audited_columns).inject({}) do |changes,(attr, old_value)|
        changes[attr] = [old_value, self[attr]]
        changes
      end
    end

    def audited_attributes
      attributes.except(*non_audited_columns)
    end

    def audit_create
      write_audit(auditable_id: self.id, auditable_type: self.class.to_s, audited_changes: audited_attributes)
    end

    def audit_update
      if (changes = audited_changes).present?
        write_audit(auditable_id: self.id, auditable_type: self.class.to_s, audited_changes: changes)
      end
    end

    def audit_destroy
      unless self.new_record?
        write_audit(auditable_id: self.id, auditable_type: self.class.to_s, audited_changes: audited_attributes)
      end
    end

    def write_audit(attrs)
      self.audit_clazz.create(attrs)
    end

    def set_version_number
      max = self.class.where(
        :auditable_id => auditable_id,
        :auditable_type => auditable_type
      ).order(:version.desc).first.try(:version) || 0
      self.version = max + 1
    end
end

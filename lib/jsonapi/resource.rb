require 'jsonapi/callbacks'
require 'jsonapi/relationship_builder'

module JSONAPI
  class Resource
    include Callbacks

    attr_reader :context

    define_jsonapi_resources_callbacks :create,
                                       :update,
                                       :remove,
                                       :save,
                                       :create_to_many_link,
                                       :replace_to_many_links,
                                       :create_to_one_link,
                                       :replace_to_one_link,
                                       :replace_polymorphic_to_one_link,
                                       :remove_to_many_link,
                                       :remove_to_one_link,
                                       :replace_fields

    def initialize(model, context)
      @model = model
      @context = context
      @reload_needed = false
      @changing = false
      @save_needed = false
    end

    def _model
      @model
    end

    def id
      _model.public_send(self.class._primary_key)
    end

    def is_new?
      id.nil?
    end

    def change(callback)
      completed = false

      if @changing
        run_callbacks callback do
          completed = (yield == :completed)
        end
      else
        run_callbacks is_new? ? :create : :update do
          @changing = true
          run_callbacks callback do
            completed = (yield == :completed)
          end

          completed = (save == :completed) if @save_needed || is_new?
        end
      end

      return completed ? :completed : :accepted
    end

    def remove
      run_callbacks :remove do
        _remove
      end
    end

    def create_to_many_links(relationship_type, relationship_key_values, options = {})
      change :create_to_many_link do
        _create_to_many_links(relationship_type, relationship_key_values, options)
      end
    end

    def replace_to_many_links(relationship_type, relationship_key_values, options = {})
      change :replace_to_many_links do
        _replace_to_many_links(relationship_type, relationship_key_values, options)
      end
    end

    def replace_to_one_link(relationship_type, relationship_key_value, options = {})
      change :replace_to_one_link do
        _replace_to_one_link(relationship_type, relationship_key_value, options)
      end
    end

    def replace_polymorphic_to_one_link(relationship_type, relationship_key_value, relationship_key_type, options = {})
      change :replace_polymorphic_to_one_link do
        _replace_polymorphic_to_one_link(relationship_type, relationship_key_value, relationship_key_type, options)
      end
    end

    def remove_to_many_link(relationship_type, key, options = {})
      change :remove_to_many_link do
        _remove_to_many_link(relationship_type, key, options)
      end
    end

    def remove_to_one_link(relationship_type, options = {})
      change :remove_to_one_link do
        _remove_to_one_link(relationship_type, options)
      end
    end

    def replace_fields(field_data)
      change :replace_fields do
        _replace_fields(field_data)
      end
    end

    # Override this on a resource instance to override the fetchable keys
    def fetchable_fields
      self.class.fields
    end

    # Override this on a resource to customize how the associated records
    # are fetched for a model. Particularly helpful for authorization.
    def records_for(relation_name)
      _model.public_send relation_name
    end

    def model_error_messages
      _model.errors.messages
    end

    # Add metadata to validation error objects.
    #
    # Suppose `model_error_messages` returned the following error messages
    # hash:
    #
    #   {password: ["too_short", "format"]}
    #
    # Then to add data to the validation error `validation_error_metadata`
    # could return:
    #
    #   {
    #     password: {
    #       "too_short": {"minimum_length" => 6},
    #       "format": {"requirement" => "must contain letters and numbers"}
    #     }
    #   }
    #
    # The specified metadata is then be merged into the validation error
    # object.
    def validation_error_metadata
      {}
    end

    # Override this to return resource level meta data
    # must return a hash, and if the hash is empty the meta section will not be serialized with the resource
    # meta keys will be not be formatted with the key formatter for the serializer by default. They can however use the
    # serializer's format_key and format_value methods if desired
    # the _options hash will contain the serializer and the serialization_options
    def meta(_options)
      {}
    end

    # Override this to return custom links
    # must return a hash, which will be merged with the default { self: 'self-url' } links hash
    # links keys will be not be formatted with the key formatter for the serializer by default.
    # They can however use the serializer's format_key and format_value methods if desired
    # the _options hash will contain the serializer and the serialization_options
    def custom_links(_options)
      {}
    end

    private

    def save
      run_callbacks :save do
        _save
      end
    end

    # Override this on a resource to return a different result code. Any
    # value other than :completed will result in operations returning
    # `:accepted`
    #
    # For example to return `:accepted` if your model does not immediately
    # save resources to the database you could override `_save` as follows:
    #
    # ```
    # def _save
    #   super
    #   return :accepted
    # end
    # ```
    def _save(validation_context = nil)
      unless @model.valid?(validation_context)
        fail JSONAPI::Exceptions::ValidationErrors.new(self)
      end

      if defined? @model.save
        saved = @model.save(validate: false)

        unless saved
          if @model.errors.present?
            fail JSONAPI::Exceptions::ValidationErrors.new(self)
          else
            fail JSONAPI::Exceptions::SaveFailed.new
          end
        end
      else
        saved = true
      end
      @model.reload if @reload_needed
      @reload_needed = false

      @save_needed = !saved

      :completed
    end

    def _remove
      unless @model.destroy
        fail JSONAPI::Exceptions::ValidationErrors.new(self)
      end
      :completed

    rescue ActiveRecord::DeleteRestrictionError => e
      fail JSONAPI::Exceptions::RecordLocked.new(e.message)
    end

    def reflect_relationship?(relationship, options)
      return false if !relationship.reflect ||
        (!JSONAPI.configuration.use_relationship_reflection || options[:reflected_source])

      inverse_relationship = relationship.resource_klass._relationships[relationship.inverse_relationship]
      if inverse_relationship.nil?
        warn "Inverse relationship could not be found for #{self.class.name}.#{relationship.name}. Relationship reflection disabled."
        return false
      end
      true
    end

    def _create_to_many_links(relationship_type, relationship_key_values, options)
      relationship = self.class._relationships[relationship_type]

      # check if relationship_key_values are already members of this relationship
      relation_name = relationship.relation_name(context: @context)
      existing_relations = @model.public_send(relation_name).where(relationship.primary_key => relationship_key_values)
      if existing_relations.count > 0
        # todo: obscure id so not to leak info
        fail JSONAPI::Exceptions::HasManyRelationExists.new(existing_relations.first.id)
      end

      if options[:reflected_source]
        @model.public_send(relation_name) << options[:reflected_source]._model
        return :completed
      end

      # load requested related resources
      # make sure they all exist (also based on context) and add them to relationship

      related_resources = relationship.resource_klass.find_by_keys(relationship_key_values, context: @context)

      if related_resources.count != relationship_key_values.count
        # todo: obscure id so not to leak info
        fail JSONAPI::Exceptions::RecordNotFound.new('unspecified')
      end

      reflect = reflect_relationship?(relationship, options)

      related_resources.each do |related_resource|
        if reflect
          if related_resource.class._relationships[relationship.inverse_relationship].is_a?(JSONAPI::Relationship::ToMany)
            related_resource.create_to_many_links(relationship.inverse_relationship, [id], reflected_source: self)
          else
            related_resource.replace_to_one_link(relationship.inverse_relationship, id, reflected_source: self)
          end
          @reload_needed = true
        else
          @model.public_send(relation_name) << related_resource._model
        end
      end

      :completed
    end

    def _replace_to_many_links(relationship_type, relationship_key_values, options)
      relationship = self.class._relationships[relationship_type]

      reflect = reflect_relationship?(relationship, options)

      if reflect
        existing = send("#{relationship.foreign_key}")
        to_delete = existing - (relationship_key_values & existing)
        to_delete.each do |key|
          _remove_to_many_link(relationship_type, key, reflected_source: self)
        end

        to_add = relationship_key_values - (relationship_key_values & existing)
        _create_to_many_links(relationship_type, to_add, {})

        @reload_needed = true
      else
        send("#{relationship.foreign_key}=", relationship_key_values)
        @save_needed = true
      end

      :completed
    end

    def _replace_to_one_link(relationship_type, relationship_key_value, options)
      relationship = self.class._relationships[relationship_type]

      send("#{relationship.foreign_key}=", relationship_key_value)
      @save_needed = true

      :completed
    end

    def _replace_polymorphic_to_one_link(relationship_type, key_value, key_type, options)
      relationship = self.class._relationships[relationship_type.to_sym]
      polymorphic_type = self.class.resource_for(key_type.to_s)._model_name

      _model.public_send("#{relationship.foreign_key}=", key_value)
      _model.public_send("#{relationship.polymorphic_type}=", polymorphic_type)

      @save_needed = true

      :completed
    end

    def _remove_to_many_link(relationship_type, key, options)
      relationship = self.class._relationships[relationship_type]

      reflect = reflect_relationship?(relationship, options)

      if reflect

        related_resource = relationship.resource_klass.find_by_key(key, context: @context)

        if related_resource.nil?
          fail JSONAPI::Exceptions::RecordNotFound.new(key)
        else
          if related_resource.class._relationships[relationship.inverse_relationship].is_a?(JSONAPI::Relationship::ToMany)
            related_resource.remove_to_many_link(relationship.inverse_relationship, id, reflected_source: self)
          else
            related_resource.remove_to_one_link(relationship.inverse_relationship, reflected_source: self)
          end
        end

        @reload_needed = true
      else
        @model.public_send(relationship.relation_name(context: @context)).delete(key)
      end

      :completed

    rescue ActiveRecord::DeleteRestrictionError => e
      fail JSONAPI::Exceptions::RecordLocked.new(e.message)
    rescue ActiveRecord::RecordNotFound
      fail JSONAPI::Exceptions::RecordNotFound.new(key)
    end

    def _remove_to_one_link(relationship_type, options)
      relationship = self.class._relationships[relationship_type]

      send("#{relationship.foreign_key}=", nil)
      @save_needed = true

      :completed
    end

    def _replace_fields(field_data)
      field_data[:attributes].each do |attribute, value|
        begin
          send "#{attribute}=", value
          @save_needed = true
        rescue ArgumentError
          # :nocov: Will be thrown if an enum value isn't allowed for an enum. Currently not tested as enums are a rails 4.1 and higher feature
          raise JSONAPI::Exceptions::InvalidFieldValue.new(attribute, value)
          # :nocov:
        end
      end

      field_data[:to_one].each do |relationship_type, value|
        if value.nil?
          remove_to_one_link(relationship_type)
        else
          case value
          when Hash
            replace_polymorphic_to_one_link(relationship_type.to_s, value.fetch(:id), value.fetch(:type))
          else
            replace_to_one_link(relationship_type, value)
          end
        end
      end if field_data[:to_one]

      field_data[:to_many].each do |relationship_type, values|
        replace_to_many_links(relationship_type, values)
      end if field_data[:to_many]

      :completed
    end

    class << self
      def inherited(subclass)
        subclass.abstract(false)
        subclass.immutable(false)
        subclass._attributes = (_attributes || {}).dup
        subclass._model_hints = (_model_hints || {}).dup

        subclass._relationships = {}
        # Add the relationships from the base class to the subclass using the original options
        if _relationships.is_a?(Hash)
          _relationships.each_value do |relationship|
            options = relationship.options.dup
            options[:parent_resource] = subclass
            subclass._add_relationship(relationship.class, relationship.name, options)
          end
        end

        subclass._allowed_filters = (_allowed_filters || Set.new).dup

        type = subclass.name.demodulize.sub(/Resource$/, '').underscore
        subclass._type = type.pluralize.to_sym

        unless subclass._attributes[:id]
          subclass.attribute :id, format: :id
        end

        check_reserved_resource_name(subclass._type, subclass.name)
      end

      def resource_for(type)
        type = type.underscore
        type_with_module = type.include?('/') ? type : module_path + type

        resource_name = _resource_name_from_type(type_with_module)
        resource = resource_name.safe_constantize if resource_name
        if resource.nil?
          fail NameError, "JSONAPI: Could not find resource '#{type}'. (Class #{resource_name} not found)"
        end
        resource
      end

      def resource_for_model(model)
        resource_for(resource_type_for(model))
      end

      def _resource_name_from_type(type)
        "#{type.to_s.underscore.singularize}_resource".camelize
      end

      def resource_type_for(model)
        model_name = model.class.to_s.underscore
        if _model_hints[model_name]
          _model_hints[model_name]
        else
          model_name.rpartition('/').last
        end
      end

      attr_accessor :_attributes, :_relationships, :_allowed_filters, :_type, :_paginator, :_model_hints

      def create(context)
        new(create_model, context)
      end

      def create_model
        _model_class.new
      end

      def routing_options(options)
        @_routing_resource_options = options
      end

      def routing_resource_options
        @_routing_resource_options ||= {}
      end

      # Methods used in defining a resource class
      def attributes(*attrs)
        options = attrs.extract_options!.dup
        attrs.each do |attr|
          attribute(attr, options)
        end
      end

      def attribute(attr, options = {})
        check_reserved_attribute_name(attr)

        if (attr.to_sym == :id) && (options[:format].nil?)
          ActiveSupport::Deprecation.warn('Id without format is no longer supported. Please remove ids from attributes, or specify a format.')
        end

        check_duplicate_attribute_name(attr) if options[:format].nil?

        @_attributes ||= {}
        @_attributes[attr] = options
        define_method attr do
          @model.public_send(options[:delegate] ? options[:delegate].to_sym : attr)
        end unless method_defined?(attr)

        define_method "#{attr}=" do |value|
          @model.public_send("#{options[:delegate] ? options[:delegate].to_sym : attr}=", value)
        end unless method_defined?("#{attr}=")
      end

      def default_attribute_options
        { format: :default }
      end

      def relationship(*attrs)
        options = attrs.extract_options!
        klass = case options[:to]
                  when :one
                    Relationship::ToOne
                  when :many
                    Relationship::ToMany
                  else
                    #:nocov:#
                    fail ArgumentError.new('to: must be either :one or :many')
                    #:nocov:#
                end
        _add_relationship(klass, *attrs, options.except(:to))
      end

      def has_one(*attrs)
        _add_relationship(Relationship::ToOne, *attrs)
      end

      def belongs_to(*attrs)
        ActiveSupport::Deprecation.warn "In #{name} you exposed a `has_one` relationship "\
                                        " using the `belongs_to` class method. We think `has_one`" \
                                        " is more appropriate. If you know what you're doing," \
                                        " and don't want to see this warning again, override the" \
                                        " `belongs_to` class method on your resource."
        _add_relationship(Relationship::ToOne, *attrs)
      end

      def has_many(*attrs)
        _add_relationship(Relationship::ToMany, *attrs)
      end

      def model_name(model, options = {})
        @_model_name = model.to_sym

        model_hint(model: @_model_name, resource: self) unless options[:add_model_hint] == false
      end

      def model_hint(model: _model_name, resource: _type)
        resource_type = ((resource.is_a?(Class)) && (resource < JSONAPI::Resource)) ? resource._type : resource.to_s

        _model_hints[model.to_s.gsub('::', '/').underscore] = resource_type.to_s
      end

      def filters(*attrs)
        @_allowed_filters.merge!(attrs.inject({}) { |h, attr| h[attr] = {}; h })
      end

      def filter(attr, *args)
        @_allowed_filters[attr.to_sym] = args.extract_options!
      end

      def primary_key(key)
        @_primary_key = key.to_sym
      end

      # TODO: remove this after the createable_fields and updateable_fields are phased out
      # :nocov:
      def method_missing(method, *args)
        if method.to_s.match /createable_fields/
          ActiveSupport::Deprecation.warn('`createable_fields` is deprecated, please use `creatable_fields` instead')
          creatable_fields(*args)
        elsif method.to_s.match /updateable_fields/
          ActiveSupport::Deprecation.warn('`updateable_fields` is deprecated, please use `updatable_fields` instead')
          updatable_fields(*args)
        else
          super
        end
      end
      # :nocov:

      # Override in your resource to filter the updatable keys
      def updatable_fields(_context = nil)
        _updatable_relationships | _attributes.keys - [:id]
      end

      # Override in your resource to filter the creatable keys
      def creatable_fields(_context = nil)
        _updatable_relationships | _attributes.keys - [:id]
      end

      # Override in your resource to filter the sortable keys
      def sortable_fields(_context = nil)
        _attributes.keys
      end

      def fields
        _relationships.keys | _attributes.keys
      end

      def resolve_relationship_names_to_relations(resource_klass, model_includes, options = {})
        case model_includes
          when Array
            return model_includes.map do |value|
              resolve_relationship_names_to_relations(resource_klass, value, options)
            end
          when Hash
            model_includes.keys.each do |key|
              relationship = resource_klass._relationships[key]
              value = model_includes[key]
              model_includes.delete(key)
              model_includes[relationship.relation_name(options)] = resolve_relationship_names_to_relations(relationship.resource_klass, value, options)
            end
            return model_includes
          when Symbol
            relationship = resource_klass._relationships[model_includes]
            return relationship.relation_name(options)
        end
      end

      def apply_includes(records, options = {})
        include_directives = options[:include_directives]
        if include_directives
          model_includes = resolve_relationship_names_to_relations(self, include_directives.model_includes, options)
          records = records.includes(model_includes)
        end

        records
      end

      def apply_pagination(records, paginator, order_options)
        records = paginator.apply(records, order_options) if paginator
        records
      end

      def apply_sort(records, order_options, _context = {})
        if order_options.any?
           order_options.each_pair do |field, direction|
            if field.to_s.include?(".")
              *model_names, column_name = field.split(".")

              associations = _lookup_association_chain([records.model.to_s, *model_names])
              joins_query = _build_joins([records.model, *associations])

              # _sorting is appended to avoid name clashes with manual joins eg. overriden filters
              order_by_query = "#{associations.last.name}_sorting.#{column_name} #{direction}"
              records = records.joins(joins_query).order(order_by_query)
            else
              records = records.order(field => direction)
            end
          end
        end

        records
      end

      def _lookup_association_chain(model_names)
        associations = []
        model_names.inject do |prev, current|
          association = prev.classify.constantize.reflect_on_all_associations.detect do |assoc|
            assoc.name.to_s.downcase == current.downcase
          end
          associations << association
          association.class_name
        end

        associations
      end

      def _build_joins(associations)
        joins = []

        associations.inject do |prev, current|
          joins << "LEFT JOIN #{current.table_name} AS #{current.name}_sorting ON #{current.name}_sorting.id = #{prev.table_name}.#{current.foreign_key}"
          current
        end
        joins.join("\n")
      end

      def apply_filter(records, filter, value, options = {})
        strategy = _allowed_filters.fetch(filter.to_sym, Hash.new)[:apply]

        if strategy
          if strategy.is_a?(Symbol) || strategy.is_a?(String)
            send(strategy, records, value, options)
          else
            strategy.call(records, value, options)
          end
        else
          records.where(filter => value)
        end
      end

      def apply_filters(records, filters, options = {})
        required_includes = []

        if filters
          filters.each do |filter, value|
            if _relationships.include?(filter)
              if _relationships[filter].belongs_to?
                records = apply_filter(records, _relationships[filter].foreign_key, value, options)
              else
                required_includes.push(filter.to_s)
                records = apply_filter(records, "#{_relationships[filter].table_name}.#{_relationships[filter].primary_key}", value, options)
              end
            else
              records = apply_filter(records, filter, value, options)
            end
          end
        end

        if required_includes.any?
          records = apply_includes(records, options.merge(include_directives: IncludeDirectives.new(self, required_includes, force_eager_load: true)))
        end

        records
      end

      def filter_records(filters, options, records = records(options))
        records = apply_filters(records, filters, options)
        apply_includes(records, options)
      end

      def sort_records(records, order_options, context = {})
        apply_sort(records, order_options, context)
      end

      # Assumes ActiveRecord's counting. Override if you need a different counting method
      def count_records(records)
        records.count(:all)
      end

      def find_count(filters, options = {})
        count_records(filter_records(filters, options))
      end

      # Override this method if you have more complex requirements than this basic find method provides
      def find(filters, options = {})
        context = options[:context]

        records = filter_records(filters, options)

        sort_criteria = options.fetch(:sort_criteria) { [] }
        order_options = construct_order_options(sort_criteria)
        records = sort_records(records, order_options, context)

        records = apply_pagination(records, options[:paginator], order_options)

        resources_for(records, context)
      end

      def resources_for(records, context)
        records.collect do |model|
          resource_class = self.resource_for_model(model)
          resource_class.new(model, context)
        end
      end

      def find_by_keys(keys, options = {})
        context = options[:context]
        records = records(options)
        records = apply_includes(records, options)
        models = records.where({_primary_key => keys})
        models.collect do |model|
          self.resource_for_model(model).new(model, context)
        end
      end

      def find_by_key(key, options = {})
        context = options[:context]
        records = records(options)
        records = apply_includes(records, options)
        model = records.where({_primary_key => key}).first
        fail JSONAPI::Exceptions::RecordNotFound.new(key) if model.nil?
        self.resource_for_model(model).new(model, context)
      end

      # Override this method if you want to customize the relation for
      # finder methods (find, find_by_key)
      def records(_options = {})
        _model_class.all
      end

      def verify_filters(filters, context = nil)
        verified_filters = {}
        filters.each do |filter, raw_value|
          verified_filter = verify_filter(filter, raw_value, context)
          verified_filters[verified_filter[0]] = verified_filter[1]
        end
        verified_filters
      end

      def is_filter_relationship?(filter)
        filter == _type || _relationships.include?(filter)
      end

      def verify_filter(filter, raw, context = nil)
        filter_values = []
        if raw.present?
          filter_values += raw.is_a?(String) ? CSV.parse_line(raw) : [raw]
        end

        strategy = _allowed_filters.fetch(filter, Hash.new)[:verify]

        if strategy
          if strategy.is_a?(Symbol) || strategy.is_a?(String)
            values = send(strategy, filter_values, context)
          else
            values = strategy.call(filter_values, context)
          end
          [filter, values]
        else
          if is_filter_relationship?(filter)
            verify_relationship_filter(filter, filter_values, context)
          else
            verify_custom_filter(filter, filter_values, context)
          end
        end
      end

      def key_type(key_type)
        @_resource_key_type = key_type
      end

      def resource_key_type
        @_resource_key_type ||= JSONAPI.configuration.resource_key_type
      end

      def verify_key(key, context = nil)
        key_type = resource_key_type

        case key_type
        when :integer
          return if key.nil?
          Integer(key)
        when :string
          return if key.nil?
          if key.to_s.include?(',')
            raise JSONAPI::Exceptions::InvalidFieldValue.new(:id, key)
          else
            key
          end
        when :uuid
          return if key.nil?
          if key.to_s.match(/^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/)
            key
          else
            raise JSONAPI::Exceptions::InvalidFieldValue.new(:id, key)
          end
        else
          key_type.call(key, context)
        end
      rescue
        raise JSONAPI::Exceptions::InvalidFieldValue.new(:id, key)
      end

      # override to allow for key processing and checking
      def verify_keys(keys, context = nil)
        return keys.collect do |key|
          verify_key(key, context)
        end
      end

      # Either add a custom :verify labmda or override verify_custom_filter to allow for custom filters
      def verify_custom_filter(filter, value, _context = nil)
        [filter, value]
      end

      # Either add a custom :verify labmda or override verify_relationship_filter to allow for custom
      # relationship logic, such as uuids, multiple keys or permission checks on keys
      def verify_relationship_filter(filter, raw, _context = nil)
        [filter, raw]
      end

      # quasi private class methods
      def _attribute_options(attr)
        default_attribute_options.merge(@_attributes[attr])
      end

      def _updatable_relationships
        @_relationships.map { |key, _relationship| key }
      end

      def _relationship(type)
        type = type.to_sym
        @_relationships[type]
      end

      def _model_name
        _abstract ? '' : @_model_name ||= name.demodulize.sub(/Resource$/, '')
      end

      def _primary_key
        @_primary_key ||= _model_class.respond_to?(:primary_key) ? _model_class.primary_key : :id
      end

      def _table_name
        @_table_name ||= _model_class.respond_to?(:table_name) ? _model_class.table_name : _model_name.tableize
      end

      def _as_parent_key
        @_as_parent_key ||= "#{_type.to_s.singularize}_id"
      end

      def _allowed_filters
        !@_allowed_filters.nil? ? @_allowed_filters : { id: {} }
      end

      def _paginator
        @_paginator ||= JSONAPI.configuration.default_paginator
      end

      def paginator(paginator)
        @_paginator = paginator
      end

      def abstract(val = true)
        @abstract = val
      end

      def _abstract
        @abstract
      end

      def immutable(val = true)
        @immutable = val
      end

      def _immutable
        @immutable
      end

      def mutable?
        !@immutable
      end

      def _model_class
        return nil if _abstract

        return @model if @model
        @model = _model_name.to_s.safe_constantize
        warn "[MODEL NOT FOUND] Model could not be found for #{self.name}. If this a base Resource declare it as abstract." if @model.nil?
        @model
      end

      def _allowed_filter?(filter)
        !_allowed_filters[filter].nil?
      end

      def module_path
        if name == 'JSONAPI::Resource'
          ''
        else
          name =~ /::[^:]+\Z/ ? ($`.freeze.gsub('::', '/') + '/').underscore : ''
        end
      end

      def default_sort
        [{field: 'id', direction: :asc}]
      end

      def construct_order_options(sort_params)
        sort_params ||= default_sort

        return {} unless sort_params

        sort_params.each_with_object({}) do |sort, order_hash|
          field = sort[:field].to_s == 'id' ? _primary_key : sort[:field].to_s
          order_hash[field] = sort[:direction]
        end
      end

      def _add_relationship(klass, *attrs)
        options = attrs.extract_options!
        options[:parent_resource] = self

        attrs.each do |relationship_name|
          check_reserved_relationship_name(relationship_name)
          check_duplicate_relationship_name(relationship_name)

          JSONAPI::RelationshipBuilder.new(klass, _model_class, options)
            .define_relationship_methods(relationship_name.to_sym)
        end
      end

      # Allows JSONAPI::RelationshipBuilder to access metaprogramming hooks
      def inject_method_definition(name, body)
        define_method(name, body)
      end

      def register_relationship(name, relationship_object)
        @_relationships[name] = relationship_object
      end

      private

      def check_reserved_resource_name(type, name)
        if [:ids, :types, :hrefs, :links].include?(type)
          warn "[NAME COLLISION] `#{name}` is a reserved resource name."
          return
        end
      end

      def check_reserved_attribute_name(name)
        # Allow :id since it can be used to specify the format. Since it is a method on the base Resource
        # an attribute method won't be created for it.
        if [:type].include?(name.to_sym)
          warn "[NAME COLLISION] `#{name}` is a reserved key in #{_resource_name_from_type(_type)}."
        end
      end

      def check_reserved_relationship_name(name)
        if [:id, :ids, :type, :types].include?(name.to_sym)
          warn "[NAME COLLISION] `#{name}` is a reserved relationship name in #{_resource_name_from_type(_type)}."
        end
      end

      def check_duplicate_relationship_name(name)
        if _relationships.include?(name.to_sym)
          warn "[DUPLICATE RELATIONSHIP] `#{name}` has already been defined in #{_resource_name_from_type(_type)}."
        end
      end

      def check_duplicate_attribute_name(name)
        if _attributes.include?(name.to_sym)
          warn "[DUPLICATE ATTRIBUTE] `#{name}` has already been defined in #{_resource_name_from_type(_type)}."
        end
      end
    end
  end
end

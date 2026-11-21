# frozen_string_literal: true

require "yaml"

module Notifications
  class RuleRegistry
    RULES_PATH = Rails.root.join("config", "notification_rules.yml").freeze

    class << self
      def all(reload: Rails.env.development? || Rails.env.test?)
        @rules = nil if reload
        @rules ||= load_rules
      end

      def find(rule_id)
        all.find { |r| r["id"] == rule_id.to_s }
      end

      def by_trigger(trigger_type)
        all.select { |r| r["trigger_type"] == trigger_type.to_s && r["enabled"] != false }
      end

      private

      def load_rules
        return [] unless File.exist?(RULES_PATH)

        raw = YAML.safe_load_file(RULES_PATH, permitted_classes: [], aliases: false) || {}
        Array(raw["rules"]).map { |r| r.transform_keys(&:to_s) }
      end
    end
  end
end

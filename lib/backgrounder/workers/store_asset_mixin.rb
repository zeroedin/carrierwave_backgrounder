# encoding: utf-8

require "open-uri"
require "aws-sdk"
require "carrierwave"
require "carrierwave/storage/fog"
require "carrierwave/storage/file"
require "carrierwave/uploader"

module CarrierWave
  module Workers

    module StoreAssetMixin
      include CarrierWave::Workers::Base
      include ::Sidekiq::Status::Worker

      def self.included(base)
        base.extend CarrierWave::Workers::ClassMethods
      end

      attr_reader :cache_path, :tmp_directory

      def perform(*args)
        file = Upload.find(args[1])
        at 60, "Performing"
        status = Sidekiq::Status::get_all self.provider_job_id
        ActionCable.server.broadcast 'activity_channel', {stage: "during", job: self.to_json, status: status.to_json, file: file}

        record = super(*args)

        if record && record.send(:"#{column}_tmp")

          at 75, "Uploading"
          status = Sidekiq::Status::get_all self.provider_job_id
          ActionCable.server.broadcast 'activity_channel', {stage: "during", job: self.to_json, status: status.to_json, file: file}

          store_directories(record)

          record.send :"process_#{column}_upload=", true
          record.send :"#{column}_tmp=", nil
          record.send :"#{column}_processing=", false if record.respond_to?(:"#{column}_processing")

          at 85, "Saving"
          status = Sidekiq::Status::get_all self.provider_job_id
          ActionCable.server.broadcast 'activity_channel', {stage: "during", job: self.to_json, status: status.to_json, file: file}

          open(cache_path) do |f|
            record.send :"#{column}=", f
          end

          if record.save!
            at 95, "Cleaning up"
            status = Sidekiq::Status::get_all self.provider_job_id
            ActionCable.server.broadcast 'activity_channel', {stage: "during", job: self.to_json, status: status.to_json, file: file}
            FileUtils.rm_r(tmp_directory, :force => true)
          end
        else
          when_not_ready
        end
      end

      private

      def store_directories(record)
        asset, asset_tmp = record.send(:"#{column}"), record.send(:"#{column}_tmp")
        if is_fog?
          cache_url = "https://#{CarrierWave::Uploader::Base.fog_directory}.s3.amazonaws.com"
          @cache_path = "#{cache_url}/#{asset.cache_dir}/#{asset_tmp}"
          @tmp_directory = "#{asset.cache_dir}/#{asset_tmp}"
        else
          cache_directory  = File.expand_path(asset.cache_dir, asset.root)
          @cache_path      = File.join(cache_directory, asset_tmp)
          @tmp_directory   = File.join(cache_directory, asset_tmp.split("/").first)
        end
      end

      def is_fog?
        if CarrierWave::Uploader::Base.cache_storage == CarrierWave::Storage::Fog
          true
        elsif CarrierWave::Uploader::Base.cache_storage == CarrierWave::Storage::File
          false
        end
      end

    end # StoreAssetMixin

  end # Workers
end # Backgrounder

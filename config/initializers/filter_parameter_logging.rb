# Be sure to restart your server when you modify this file.

# Configure parameters to be filtered from the log file. Use this to limit dissemination of
# sensitive information. See the ActiveSupport::ParameterFilter documentation for supported
# notations and behaviors.
# PRIVACY COMPLIANCE INVARIANT: Camera frames (:images_base64, :image_base64, :images, :frames)
# are processed strictly in ephemeral RAM and must NEVER be written to application logs.
Rails.application.config.filter_parameters += [
  :passw, :secret, :token, :_key, :crypt, :salt, :certificate, :otp, :ssn,
  :images_base64, :image_base64, :images, :frames
]

# frozen_string_literal: true

require_relative 'csob'

$stdout.sync = true

run CSOB.freeze.app

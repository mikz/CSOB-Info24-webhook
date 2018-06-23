# frozen_string_literal: true

require 'roda'
require 'json'
require 'net/http'

class CSOB < Roda
  route do |r|
    r.root do
    end

    r.on 'mailgun' do
      r.post do
        r.is 'message' do
          transactions = Transaction.extract request.params.fetch('stripped-text')
          web_hook = WebHook.new(ENV.fetch('WEBHOOK_URL'))

          puts "found #{transactions.size} transactions"
          transactions.each do |t|
            res = web_hook.post(t)
            puts "delivered webhook. status: #{res.code}"
          end

          response.status = 204
          nil
        end
      end
    end
  end

  class WebHook
    def initialize(url)
      @url = URI(url)

      @net_http = Net::HTTP.new(@url.hostname, @url.port)
      @net_http.use_ssl = @url.scheme == 'https'
      @net_http.start
    end

    def post(payload)
      @net_http.post(@url, payload.to_json, 'Content-Type' => 'application/json')
    end
  end

  module Transaction
    # noinspection RegExpRepeatedSpace
    EXTRACT_BANK_TRANSACTION = /
      dne\s(.+?)\s[[:word:]]+\sna\súčtu\s(\d+)\s[[:word:]]+\s(.+?):[[:space:]]+
      (.+?)[[:space:]]+
      Zůstatek\sna\súčtu\spo\szaúčtování\stransakce:\s([^\r\n]+)
    /mx

    EXTRACT_CARD_TRANSACTION = /(\S+)\s(\S+)\s.+?\s'\*(\d+)' na částku (.+?). Místo: (.+?)\.[[:space:]]+/

    Money = Struct.new(:amount, :currency) do
      def to_json(options = nil)
        { amount: amount, currency: currency }.to_json(options)
      end

      def to_s
        "#{amount} #{currency}"
      end
    end

    def self.parse_money(money)
      amount, currency = money.split(' ')

      int, frac = amount.split(',').map(&Kernel.method(:Integer))


      Money.new((int.abs + (frac.to_f / 100)) * (int / int.abs), currency)
    end

    def self.parse_details(line)
      Details.new(
        line.strip
            .split(/\n+/)
            .slice_when { |_, a| a.match(/:$/) }
            .reject { |slice| slice.size == 1 && slice.first.match(':') }
            .to_a
      )
    end

    def self.extract(text)
      bank_transactions = text.scan(EXTRACT_BANK_TRANSACTION)
                              .map do |(date, account, kind, details, balance)|
        BankTransaction.new(Date.strptime(date, '%d.%m.%Y'),
                            account,
                            kind,
                            parse_details(details),
                            parse_money(balance))
      end

      card_transactions = text.scan(EXTRACT_CARD_TRANSACTION)
                              .map do |(date, time, card, amount, location)|

        time = Time.strptime(time, '%H:%M', Date.strptime(date, '%d.%m.%Y').to_time)
        CardTransaction.new(time, card, parse_money(amount), location)
      end

      bank_transactions + card_transactions
    end

    class Details
      def initialize(details)
        @details = details
        @amount = Transaction.parse_money field_value('částka')
      end

      attr_reader :amount

      def to_json(options = nil)
        to_h.to_json(options)
      end

      def to_h
        details.map do |chunk|
          [chunk.first, chunk.slice(1, chunk.size)] if chunk.first.match?(':')
        end.compact.to_h
      end

      def to_s
        details.map do |chunk|
          if chunk.first.match?(':')
            "#{chunk.first} #{chunk.slice(1, chunk.size).join(', ')}"
          else
            chunk.join(', ')
          end
        end.join(', ')
      end

      protected

      def find_field(name)
        pattern = /^#{Regexp.quote(name)}\s/
        details.flatten.find { |detail| detail.match(pattern) }
      end

      def field_value(name)
        field = find_field(name)
        field.delete_prefix(name).strip
      end

      attr_reader :details
    end

    class BankTransaction
      def initialize(date, account, kind, details, balance)
        @date = date
        @account = account
        @kind = kind.sub(/^./) {|m| m.upcase }
        @details = details
        @balance = balance
      end

      attr_reader :date, :account, :kind, :details, :balance

      def amount
        details.amount
      end
      def to_json(options = nil)
        {
          date: date,
          amount: amount,
          account: account,
          kind: kind,
          details: details,
          balance: balance,
          notification: notification,
          title: title
        }.to_json(options)
      end

      def notification
        <<~TEXT.strip
          #{kind} #{date.strftime('%d. %-m. %Y')} #{details}
        TEXT
      end

      def title
        "#{kind} #{amount}"
      end
    end

    class CardTransaction
      def initialize(time, card, amount, location)
        @time = time
        @card = card
        @amount = amount
        @location = location
      end

      def notification
        <<~TEXT.strip
          Autorizace (#{card}): #{amount}, #{time.strftime('%H:%M')}, #{location}
        TEXT
      end

      def title
        "CSOB autorizace karty #{card}"
      end

      attr_reader :time, :card, :amount, :location

      def to_json(options = nil)
        { time: time,
          amount: amount,
          card: card,
          location: location,
          notification: notification, title: title }.to_json(options)
      end
    end
  end
end

# name: discourse-webhook-digest
# about: Discourse Webhook Digest
# authors: michael@discoursehosting.com
# version: 1.0
# url: https://github.com/discoursehosting/discourse-webhook-digest


enabled_site_setting :webhook_digest_enabled

after_initialize {

  class ::Jobs::EnqueueDigestWebhooks  < Jobs::Scheduled
    every 30.seconds
    
    def execute(args)
      return unless SiteSetting.webhook_digest_enabled
      DigestWebhooks.generate
    end
  end
  
  class ::DigestWebhooks
    def self.generate
      user_ids = Jobs::EnqueueDigestEmails.new.target_user_ids
      user_ids = User.real.pluck(:id) # @debug 
      users = User.where(id: user_ids)
      return if users.blank?
      users.each do |user|
        payload = {}
        payload['json'] = UserJsonNotifications::json_digest(user)
        digest = ::UserNotifications::digest(user)
        payload['html'] = digest.html_part.body.raw_source
        puts JSON.pretty_generate(payload) # @debug
        # TODO send it
      end
    end
  end
  
  #module ::PrependUserNotifications 
  class ::UserJsonNotifications 

    # need to copy some private methods from UserNotifications
    
    def self.summary_new_users_count_key(min_date_str)
      "summary-new-users:#{min_date_str}"
    end

    def self.summary_new_users_count(min_date)
      min_date_str = min_date.is_a?(String) ? min_date : min_date.strftime('%Y-%m-%d')
      key = summary_new_users_count_key(min_date_str)
      ((count = $redis.get(key)) && count.to_i) || begin
        count = User.real.where(active: true, staged: false).not_suspended.where("created_at > ?", min_date_str).count
        $redis.setex(key, 1.day, count)
        count
      end
    end
  
    def self.short_date(dt)
      if dt.year == Time.now.year
        I18n.l(dt, format: :short_no_year)
      else
        I18n.l(dt, format: :date_only)
      end
    end

    def self.first_paragraphs_from(html)
      doc = Nokogiri::HTML(html)

      result = +""
      length = 0

      doc.css('body > p, aside.onebox, body > ul, body > blockquote').each do |node|
        if node.text.present?
          result << node.to_s
          length += node.inner_text.length
          return result if length >= SiteSetting.digest_min_excerpt_length
        end
      end

      return result unless result.blank?

      # If there is no first paragaph with text, return the first paragraph with
      # something else (an image) or div (a onebox).
      doc.css('body > p, body > div').first
    end

    def self.email_excerpt(html_arg, post = nil)
      html = (first_paragraphs_from(html_arg) || html_arg).to_s
      PrettyText.format_for_email(html, post).html_safe
    end
  
    # end copied methods
    
    def self.json_digest(user, opts = {})
        opts = {}

        min_date = opts[:since] || user.last_emailed_at || user.last_seen_at || 1.month.ago
        min_date = 1.month.ago # @debug
        digest_opts = { limit: SiteSetting.digest_topics + SiteSetting.digest_other_topics, top_order: true }
        topics_for_digest = Topic.for_digest(user, min_date, digest_opts).to_a
        if topics_for_digest.empty? && !user.user_option.try(:include_tl0_in_digests)
          # Find some topics from new users that are at least 24 hours old
          topics_for_digest = Topic.for_digest(user, min_date, digest_opts.merge(include_tl0: true)).where('topics.created_at < ?', 24.hours.ago).to_a
        end

        popular_topics = topics_for_digest[0, SiteSetting.digest_topics]
        if popular_topics.present?
        
          other_new_for_you = topics_for_digest.size > SiteSetting.digest_topics ? topics_for_digest[SiteSetting.digest_topics..-1] : []

          popular_posts = if SiteSetting.digest_posts > 0
            Post.order("posts.score DESC")
              .for_mailing_list(user, min_date)
              .where('posts.post_type = ?', Post.types[:regular])
              .where('posts.deleted_at IS NULL AND posts.hidden = false AND posts.user_deleted = false')
              .where("posts.post_number > ? AND posts.score > ?", 1, ScoreCalculator.default_score_weights[:like_score] * 5.0)
              .where('posts.created_at < ?', (SiteSetting.editing_grace_period || 0).seconds.ago)
              .limit(SiteSetting.digest_posts)
          else
            []
          end
          
          excerpts = {}
          popular_topics.map do |t|
            if t.first_post.present?
              excerpt = email_excerpt(t.first_post.cooked, t.first_post)
              excerpts[t.first_post.id] = excerpt
              t.excerpt = excerpt
            end
          end

          # Try to find 3 interesting stats for the top of the digest
          new_topics_count = Topic.for_digest(user, min_date).count

          if new_topics_count == 0
            # We used topics from new users instead, so count should match
            new_topics_count = topics_for_digest.size
          end
          counts = [{ label_key: 'user_notifications.digest.new_topics',
                       value: new_topics_count,
                       href: "#{Discourse.base_url}/new" }]

          value = user.unread_notifications
          counts << { label_key: 'user_notifications.digest.unread_notifications', value: value, href: "#{Discourse.base_url}/my/notifications" } if value > 0

          value = user.unread_private_messages
          counts << { label_key: 'user_notifications.digest.unread_messages', value: value, href: "#{Discourse.base_url}/my/messages" } if value > 0

          if counts.size < 3
            value = user.unread_notifications_of_type(Notification.types[:liked])
            counts << { label_key: 'user_notifications.digest.liked_received', value: value, href: "#{Discourse.base_url}/my/notifications" } if value > 0
          end

          if counts.size < 3 && user.user_option.digest_after_minutes >= 1440
            value = summary_new_users_count(min_date)
            counts << { label_key: 'user_notifications.digest.new_users', value: value, href: "#{Discourse.base_url}/about" } if value > 0
          end

          last_seen_at = short_date(user.last_seen_at || user.created_at)
          preheader_text = I18n.t('user_notifications.digest.preheader', last_seen_at: last_seen_at)
        end
        result = [ :user_id => user.id, :username => user.username, :last_seen_at => last_seen_at, :preheader_text => preheader_text, :popular_topics => popular_topics.as_json, :counts => counts, :other_new_for_you => other_new_for_you.as_json ]
        result
    end
  end

}
#!/bin/bash

cd /var/www/discourse/plugins/discourse-community-plugins
git pull
su discourse -c "cd /var/www/discourse && RAILS_ENV=production bundle exec rake tmp:clear assets:clean assets:precompile"
sv restart unicorn
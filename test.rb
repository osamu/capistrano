load 'deploy'
set :application, 'foo'
set :scm, "none"
set :repository, '/home/osamu/code/capistrano'

set :rsync_server, "localhost:/tmp/rsyncserver/"

set :deploy_to, "/tmp/myroot/#{application}"
set :deploy_via, :rsync                             # select strategy 

set :use_sudo, false
set :shared_children, %w()

role :web, 'localhost' 

require 'support/shared/integration/integration_helper'
require 'chef/mixin/shell_out'

describe "LWRPs with inline resources" do
  include IntegrationSupport
  include Chef::Mixin::ShellOut

  let(:chef_dir) { File.expand_path("../../../../bin", __FILE__) }

  # Invoke `chef-client` as `ruby PATH/TO/chef-client`. This ensures the
  # following constraints are satisfied:
  # * Windows: windows can only run batch scripts as bare executables. Rubygems
  # creates batch wrappers for installed gems, but we don't have batch wrappers
  # in the source tree.
  # * Other `chef-client` in PATH: A common case is running the tests on a
  # machine that has omnibus chef installed. In that case we need to ensure
  # we're running `chef-client` from the source tree and not the external one.
  # cf. CHEF-4914
  let(:chef_client) { "ruby '#{chef_dir}/chef-client' --minimal-ohai" }

  context "with a use_inline_resources provider with 'def action_a' instead of action :a" do
    class LwrpInlineResourcesTest < Chef::Resource::LWRPBase
      resource_name :lwrp_inline_resources_test
      actions :a, :nothing
      default_action :a
      property :ran_a
      class Provider < Chef::Provider::LWRPBase
        provides :lwrp_inline_resources_test
        use_inline_resources
        def action_a
          r = new_resource
          ruby_block 'run a' do
            block { r.ran_a "ran a" }
          end
        end
      end
    end

    it "this is totally a bug, but for backcompat purposes, it adds the resources to the main resource collection and does not get marked updated" do
      r = nil
      expect_recipe {
        r = lwrp_inline_resources_test 'hi'
      }.to have_updated('ruby_block[run a]', :run)
      expect(r.ran_a).to eq "ran a"
    end
  end

  context "with an inline_resources provider with two actions, one calling the other" do
    class LwrpInlineResourcesTest2 < Chef::Resource::LWRPBase
      resource_name :lwrp_inline_resources_test2
      actions :a, :b, :nothing
      default_action :b
      property :ran_a
      property :ran_b
      class Provider < Chef::Provider::LWRPBase
        provides :lwrp_inline_resources_test2
        use_inline_resources

        action :a do
          r = new_resource
          ruby_block 'run a' do
            block { r.ran_a "ran a" }
          end
        end

        action :b do
          action_a
          r = new_resource
          # Grab ran_a right now, before we converge
          ran_a = r.ran_a
          ruby_block 'run b' do
            block { r.ran_b "ran b: ran_a value was #{ran_a.inspect}" }
          end
        end
      end
    end

    it "resources declared in b are executed immediately inline" do
      r = nil
      expect_recipe {
        r = lwrp_inline_resources_test2 'hi' do
          action :b
        end
      }.to have_updated('lwrp_inline_resources_test2[hi]', :b).
       and have_updated('ruby_block[run a]', :run).
       and have_updated('ruby_block[run b]', :run)
      expect(r.ran_b).to eq "ran b: ran_a value was \"ran a\""
    end
  end

  when_the_repository "has a cookbook with a nested LWRP" do
    before do
      directory 'cookbooks/x' do

        file 'resources/do_nothing.rb', <<-EOM
          actions :create, :nothing
          default_action :create
        EOM
        file 'providers/do_nothing.rb', <<-EOM
          action :create do
          end
        EOM

        file 'resources/my_machine.rb', <<-EOM
          actions :create, :nothing
          default_action :create
        EOM
        file 'providers/my_machine.rb', <<-EOM
          use_inline_resources
          action :create do
            x_do_nothing 'a'
            x_do_nothing 'b'
          end
        EOM

        file 'recipes/default.rb', <<-EOM
          x_my_machine "me"
          x_my_machine "you"
        EOM

      end # directory 'cookbooks/x'
    end

    it "should complete with success" do
      file 'config/client.rb', <<EOM
local_mode true
cookbook_path "#{path_to('cookbooks')}"
log_level :warn
EOM

      result = shell_out("#{chef_client} -c \"#{path_to('config/client.rb')}\" --no-color -F doc -o 'x::default'", :cwd => chef_dir)
      actual = result.stdout.lines.map { |l| l.chomp }.join("\n")
      expected = <<EOM
  * x_my_machine[me] action create
    * x_do_nothing[a] action create (up to date)
    * x_do_nothing[b] action create (up to date)
     (up to date)
  * x_my_machine[you] action create
    * x_do_nothing[a] action create (up to date)
    * x_do_nothing[b] action create (up to date)
     (up to date)
EOM
      expected = expected.lines.map { |l| l.chomp }.join("\n")
      expect(actual).to include(expected)
      result.error!
    end
  end
end

##! This is an extension/replacement for protocols/conn/known_hosts.bro that
##! adds reverse DNS queries to the known_hosts table.  The reason for doing
##! this is to support a re-write of protocols/ssh/interesting-hostnames to
##! remove all of the redundant DNS queries. However, having the hostnames
##! available via Known::hosts may be useful in other cases.
##! (Yes, in edge cases it would violate the TTL of the DNS records.)

##! This script logs hosts that Bro determines have performed complete TCP 
##! handshakes and logs the address once per day (by default).  The log that 
##! is output provides an easy way to determine a count of the IP addresses in
##! use on a network per day.

@load base/utils/directions-and-hosts
@load base/frameworks/cluster

module Known;

export {
	## The known-hosts logging stream identifier.
	redef enum Log::ID += { HOSTS_LOG };

	## The record type which contains the column fields of the known-hosts log.
	type HostsInfo: record {
		## The timestamp at which the host was detected.
		ts:      time &log;
		## The address that was detected originating or responding to a
		## TCP connection.
		host:    addr &log;
		## If DNS lookup fails we'll actually see "<???>"
		name:	string &log &default="unknown";
	};

	## Toggles between different implementations of this script.
	## When true, use a Broker data store, else use a regular Bro set
	## with keys uniformly distributed over proxy nodes in cluster
	## operation.
	const use_host_store = T &redef;
	
	## The hosts whose existence should be logged and tracked.
	## See :bro:type:`Host` for possible choices.
	const host_tracking = LOCAL_HOSTS &redef;
	
	## Holds the set of all known hosts.  Keys in the store are addresses
	## and their associated value will always be the "true" boolean.
	global host_store: Cluster::StoreInfo;

	## The Broker topic name to use for :bro:see:`Known::host_store`.
	const host_store_name = "bro/known/hosts" &redef;

	## The expiry interval of new entries in :bro:see:`Known::host_store`.
	## This also changes the interval at which hosts get logged.
	const host_store_expiry = 1day &redef;

	## The timeout interval to use for operations against
	## :bro:see:`Known::host_store`.
	const host_store_timeout = 15sec &redef;
	const dns_timeout = 10sec &redef;

	## The set of all known addresses to store for preventing duplicate 
	## logging of addresses.  It can also be used from other scripts to 
	## inspect if an address has been seen in use.
	## Maintain the list of known hosts for 24 hours so that the existence
	## of each individual address is logged each day.
	##
	## In cluster operation, this set is distributed uniformly across
	## proxy nodes.
	global hosts: table[addr] of string &create_expire=1day &redef;
	global stored_hosts: table[addr] of string;

	## An event that can be handled to access the :bro:type:`Known::HostsInfo`
	## record as it is sent on to the logging framework.
	global Known::log_known_hosts: event(rec: HostsInfo);
	global Known::manager_to_workers: event(myhosts: table[addr] of string);
	global Known::worker_to_workers: event(newhost: HostsInfo);
	global Known::send_known: event();
	global Known::host_found: event(info: HostsInfo);
}

# concept stolen from scripts/base/protocols/irc/dcc-send.bro
function known_relay_topic(): string{
	local rval = Cluster::rr_topic(Cluster::proxy_pool, "known_rr_key");

	if ( rval == "" )
		# No proxy is alive, so relay via manager instead.
		return Cluster::manager_topic;
	return rval;
}

event Known::manager_to_workers(myhosts: table[addr] of string){
	for (ip in myhosts){
		Known::hosts[ip] = myhosts[ip];
	}
}

event Known::worker_to_workers(newhost: HostsInfo){
	# Must relay through proxies (or manager)

@if ( Cluster::local_node_type() == Cluster::PROXY ||
	Cluster::local_node_type() == Cluster::MANAGER )
	Broker::publish(Cluster::worker_topic, Known::worker_to_workers, newhost);
@else
	Known::hosts[newhost$host] = newhost$name;
@endif
}

event Known::send_known(){
	Broker::publish(Cluster::worker_topic,Known::manager_to_workers,Known::stored_hosts);

	# kill it, no longer needed
	Known::stored_hosts = table();
}

# Thanks Justin for this bit to help with the name transition:
@ifndef(zeek_init)
#Running on old bro that doesn't know about zeek events
global zeek_init: event();
event bro_init()
{
    event zeek_init();
}
@endif

event zeek_init(){

        Log::create_stream(Known::HOSTS_LOG, [$columns=HostsInfo, $ev=log_known_hosts, $path="known_hosts"]);

        if ( ! Known::use_host_store )
                return;

	Known::host_store = Cluster::create_store(Known::host_store_name,T);

	@if ( ! Cluster::is_enabled() || Cluster::local_node_type() == Cluster::MANAGER )

		when ( local r = Broker::keys(Known::host_store$store)){
			if ( r$status == Broker::SUCCESS ){

				# Have to recast r$result as a set in order to work with it since
				# it's a Broker::Data type.
				for (ip in r$result as addr_set){
					when ( local res = Broker::get(Known::host_store$store,ip)){

						@if ( ! Cluster::is_enabled() )
							Known::hosts[ip] = fmt("%s",res$result as string);
						@else
							Known::stored_hosts[ip] = fmt("%s",res$result as string);
						@endif

					}timeout Known::host_store_timeout{ }
				}
			}
		}timeout Known::host_store_timeout { }

		@if ( Cluster::local_node_type() == Cluster::MANAGER)
			# essentially, we're waiting for the asynchronous Broker calls to finish populating
			# the manager's Known::stored_hosts and then sending the table to the workers all at once
			schedule 30sec {Known::send_known()};
		@endif

	@endif
}

event Known::host_found(info: HostsInfo){
	# We could also potentially have used Broker::auto_publish to call this event

	@if ( Cluster::local_node_type() == Cluster::WORKER )
		# Broker pre-2.6-beta ## Cluster::relay_rr(Cluster::proxy_pool, "known_key", Cluster::worker_topic,Known::worker_to_workers,info);
		# this obviously results in a worker seeing the same message it just sent.
		Broker::publish(known_relay_topic(),Known::worker_to_workers,info);
	@endif

	@if ( ! Cluster::is_enabled() || Cluster::local_node_type() == Cluster::MANAGER )

	# manager doesn't need it's own table after passing on the store in bro_init
	#Known::hosts[info$host] = info$name;

	if ( ! Known::use_host_store){
		Known::hosts[info$host] = info$name;
		print(fmt("Test1 %s",info));
		Log::write(Known::HOSTS_LOG, info);
	}else{
	# Add to the store and log
		when ( local r = Broker::put_unique(Known::host_store$store, info$host,
	                                    info$name, Known::host_store_expiry) ){
			if ( r$status == Broker::SUCCESS ){
				if ( r$result as bool ){
print(fmt("Test2 %s",info));
					Log::write(Known::HOSTS_LOG, info);
				}
			}else{
				Reporter::error(fmt("%s: data store put_unique failure",
					Known::host_store_name));
			}
		}
		timeout Known::host_store_timeout{
			# Can't really tell if master store ended up inserting a key.
print(fmt("Test3 %s",info));
			Log::write(Known::HOSTS_LOG, info);
		}
        }

	@endif
}

event connection_established(c: connection) &priority=5{
	if ( c$orig$state != TCP_ESTABLISHED )
		return;

	if ( c$resp$state != TCP_ESTABLISHED )
		return;

	local id = c$id;

	for ( host in set(id$orig_h, id$resp_h) ){
		if ( addr_matches_host(host, host_tracking) && host !in Known::hosts){

	# do the DNS lookup, this could get heavy when the cluster first starts without an
	# existing known_hosts table
			when ( local hostname = lookup_addr(host) ){
				event Known::host_found([$ts = network_time(), $host = host, $name=hostname]);
				@if ( Cluster::is_enabled() && Cluster::local_node_type() == Cluster::WORKER )
					Broker::publish(Cluster::manager_topic,Known::host_found,[$ts = network_time(), $host = host, $name=hostname]);				
				@endif
			}timeout Known::dns_timeout{
print("Test4 timeout");
				event Known::host_found([$ts = network_time(), $host = host, $name="unknown"]);
				@if ( Cluster::is_enabled() && Cluster::local_node_type() == Cluster::WORKER )
					Broker::publish(Cluster::manager_topic,Known::host_found,[$ts = network_time(), $host = host, $name=hostname]);				
				@endif
			}
		}
	}
}



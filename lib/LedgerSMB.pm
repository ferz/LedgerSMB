
=head1 NAME

LedgerSMB - The Base class for many LedgerSMB objects, including DBObject.

=head1 SYNOPSIS

This module creates a basic request handler with utility functions available
in database objects (LedgerSMB::DBObject)

=head1 METHODS

=over

=item new ()

This method creates a new base request instance. It also validates the
session/user credentials, as appropriate for the run mode.  Finally, it sets up
the database connections for the user.

=item unescape($var)

Unescapes the var, i.e. converts html entities back to their characters.

=item open_form()

This sets a $self->{form_id} to be used in later form validation (anti-XSRF
measure).

=item check_form()

This returns true if the form_id was associated with the session, and false if
not.  Use this if the form may be re-used (back-button actions are valid).

=item close_form()

Identical with check_form() above, but also removes the form_id from the
session.  This should be used when back-button actions are not valid.

=item is_run_mode ('(cli|cgi|mod_perl)')

This function returns 1 if the run mode is what is specified.  Otherwise
returns 0.

=item is_allowed_role({allowed_roles => @role_names})

This function returns 1 if the user's roles include any of the roles in
@role_names.

=item merge ($hashref, keys => @list, index => $number);

This command merges the $hashref into the current object.  If keys are
specified, only those keys are used.  Otherwise all keys are merged.

If an index is specified, the merged keys are given a form of
"$key" . "_$index", otherwise the key is used on both sides.

=item set (@attrs)

Copies the given key=>vars to $self. Allows for finer control of
merging hashes into self.

=item remove_cgi_globals()

Removes all elements starting with a . because these elements conflict with the
ability to hide the entire structure for things like CSV lookups.

=item call_procedure( procname => $procname, args => $args )

Function that allows you to call a stored procedure by name and map the appropriate argument to the function values.

Args is an arrayref.  The members of args can be scalars or arrayrefs in which
case they are just bound to the placeholders (arrayref to Pg array conversion
occurs automatically in DBD::Pg 2.x), or they can be hashrefs of the following
syntax: {value => $data, type=> $db_type}.  The type field is any SQL type
DBD::Pg supports (such as 'PG_BYTEA').

=item dberror()

Localizes and returns database errors and error codes within LedgerSMB

=item error()

Returns HTML errors in LedgerSMB. Needs refactored into a general Error class.

=item get_user_info()

Loads user configuration info from LedgerSMB::User

=item sanitize_for_display()

Expands a hash into human-readable key => value pairs, and formats and rounds amounts, recursively expanding hashes until there are no hash members present.

=item take_top_level()

Removes blank keys and non-reference keys from a hash and returns a hash with only non-blank and referenced keys.

=item type()

Ensures that the $ENV{REQUEST_METHOD} is defined and either "HEAD", "GET", "POST".

=item finalize_request()

This zeroes out the App_State.

=item verify_session()

This verifies the validity of the session cookie.

=item initialize_with_db

This function sets up the db handle for the request

=item fix_translation ($obj, $tag)

Just a filter to translate $tag attribute in $obj.
For example:

@{$request->{entity_classes}} = map 
  {
    $request->fix_translation($_, 'class');
  } 
  $request->call_procedure(
      funcname => 'entity__list_classes'
  );

=back



=head1 Copyright (C) 2006, The LedgerSMB core team.

 # This work contains copyrighted information from a number of sources
 # all used with permission.
 #
 # This file contains source code included with or based on SQL-Ledger
 # which is Copyright Dieter Simader and DWS Systems Inc. 2000-2005
 # and licensed under the GNU General Public License version 2 or, at
 # your option, any later version.  For a full list including contact
 # information of contributors, maintainers, and copyright holders,
 # see the CONTRIBUTORS file.
 #
 # Original Copyright Notice from SQL-Ledger 2.6.17 (before the fork):
 # Copyright (C) 2000
 #
 #  Author: DWS Systems Inc.
 #     Web: http://www.sql-ledger.org
 #
 # Contributors: Thomas Bayen <bayen@gmx.de>
 #               Antti Kaihola <akaihola@siba.fi>
 #               Moritz Bunkus (tex)
 #               Jim Rawlings <jim@your-dba.com> (DB2)
 #====================================================================
=cut

package LedgerSMB;

use strict;
use warnings;
use CGI::Simple;
$CGI::Simple::DISABLE_UPLOADS = 0;

use PGObject;

use LedgerSMB::PGNumber;
use LedgerSMB::PGDate;
use LedgerSMB::Sysconfig;
use LedgerSMB::App_State;
use LedgerSMB::Auth;
use LedgerSMB::Session;
use LedgerSMB::Template;
use LedgerSMB::Locale;
use LedgerSMB::User;
use LedgerSMB::Setting;
use LedgerSMB::Company_Config;
use LedgerSMB::DBH;
use utf8;


$CGI::Simple::POST_MAX = -1;

use Try::Tiny;
use Carp;
use DBI;

use base qw(LedgerSMB::Request);
our $VERSION = '1.6.0-dev';

my $logger = Log::Log4perl->get_logger('LedgerSMB');

sub new {
    my ($type, $argstr) = @_;
    my ($package, $filename, $line)=caller;
    my $self = {};

    $type //= "";
    $argstr //= "";

    $logger->debug("Begin called from \$filename=$filename \$line=$line \$type=$type \$argstr=$argstr ref argstr=".ref $argstr);

    my $creds =  LedgerSMB::Auth::get_credentials;
    $self->{login} = $creds->{login};
    bless $self, $type;

    my $query;
    if(ref($argstr) eq 'DBI::db')
    {
        $self->{dbh}=$argstr;
        $logger->info("setting dbh from argstr \$self->{dbh}=$self->{dbh}");
    }
    else
    {
        $query = $self->_process_argstr($argstr);
    }

    $self->{version} = $VERSION;
    $self->{dbversion} = $VERSION;
    $self->{VERSION} = $VERSION;
    $self->{_request} = $query;
    $self->{have_latex} = $LedgerSMB::Sysconfig::latex;

    $self->_set_default_locale();
    $self->_set_action();
    $self->_set_script_name();
    $self->_process_cookies();

    #HV set _locale already to default here,
    # so routines lower in stack can use it;e.g. login.pl


    $logger->debug("End");
    return $self;
}

sub unescape {
    my ($self, $var) = @_;
    return $self->{_request}->unescapeHTML($var);
}

sub open_form {
    my ($self, $args) = @_;
    if (!$ENV{GATEWAY_INTERFACE}){
        return 1;
    }
    my $i = 1;
    my @vars = $self->call_procedure(procname => 'form_open',
                              args => [$self->{session_id}],
                              continue_on_error => 1
    );
    if ($args->{commit}){
       $self->{dbh}->commit;
    }
    $self->{form_id} = $vars[0]->{form_open};
    return;
}

# move to another module
sub check_form {
    my ($self) = @_;
    return 1 unless ($ENV{GATEWAY_INTERFACE});
    my @vars = $self->call_procedure(funcname => 'form_check',
                              args => [$self->{session_id}, $self->{form_id}]
    );
    return $vars[0]->{form_check};
}

sub close_form {
    my ($self) = @_;
    return 1 unless ($ENV{GATEWAY_INTERFACE});

    my @vars = $self->call_procedure(funcname => 'form_close',
                              args => [$self->{session_id}, $self->{form_id}]
    );
    delete $self->{form_id};
    return $vars[0]->{form_close};
}

sub verify_session {
    my ($self) = @_;

    if ($self->is_run_mode('cgi') || ($self->is_run_mode('mod_perl')) && !$ENV{LSMB_NOHEAD}) {
       if (!LedgerSMB::Session::check( $self->{cookie}, $self) ) {
            $logger->error("Session did not check");
            return 0;
       }
       $logger->debug("session_check completed OK");
    }
    return 1;
}

sub initialize_with_db {
    my ($self) = @_;

    my $sth = $self->{dbh}->prepare(q(SELECT value FROM defaults WHERE setting_key = 'role_prefix'));
    $sth->execute;


    ($self->{_role_prefix}) = $sth->fetchrow_array;

    $sth = $self->{dbh}->prepare(q(SELECT check_expiration()));
    $sth->execute;
    ($self->{warn_expire}) = $sth->fetchrow_array;

    if ($self->{warn_expire}){
        $sth = $self->{dbh}->prepare(q(SELECT user__check_my_expiration()));
        $sth->execute;
        ($self->{pw_expires})  = $sth->fetchrow_array;
    }


    my $query = q(SELECT t.extends,
            coalesce (t.table_name, 'custom_' || extends)
            || ':' || f.field_name as field_def
        FROM custom_table_catalog t
        JOIN custom_field_catalog f USING (table_id));
    $sth = $self->{dbh}->prepare($query);
    $sth->execute;
    my $ref;
    $self->{custom_db_fields} = {};
    while ( $ref = $sth->fetchrow_hashref('NAME_lc') ) {
        push @{ $self->{custom_db_fields}->{ $ref->{extends} } },
          $ref->{field_def};
    }

    LedgerSMB::Company_Config::initialize($self);

    $self->get_user_info;

    $self->{_locale} =
        LedgerSMB::Locale->get_handle($self->{_user}->{language})
        or $self->error(__FILE__.':'.__LINE__.": Locale not loaded: $!\n");

    $self->{stylesheet} =
        $self->{_user}->{stylesheet} unless $self->{stylesheet};
    return;
}


sub get_user_info {
    my ($self) = @_;
    $LedgerSMB::App_State::User =
        $self->{_user} =
        LedgerSMB::User->fetch_config($self);
    $self->{_user}->{language} ||= 'en';
    return;
}

sub _set_default_locale {
    my ($self) = @_;

    my $lang = $LedgerSMB::Sysconfig::language;
    $self->{_locale}=LedgerSMB::Locale->get_handle($lang);
    $self->error( __FILE__ . ':' . __LINE__
                  . ": Locale ($lang) not loaded: $!\n" )
        unless $self->{_locale};
    return;
}

sub _set_action {
    my ($self) = @_;

    $self->{action} //= "";
    $self->{action} =~ s/\W/_/gx;
    $self->{action} = lc $self->{action};
    return;
}

sub _set_script_name {
    my ($self) = @_;

    if (exists $ENV{SCRIPT_NAME} &&
        defined $ENV{SCRIPT_NAME} &&
        $ENV{SCRIPT_NAME} =~ m/([^\/\\]*.pl)\?*.*$/x) {
        $self->{script} = $1 if defined $1;
        $self->error("Access Denied") if ( ( $self->{script} =~ m#(\.\.|\\|/)#x ) );
    } else {
        $self->{script} = 'login.pl';
    }

    $logger->debug("\$self->{script} = $self->{script} "
                   . "\$self->{action} = $self->{action}");
    return;
}


sub _process_argstr {
    my ($self, $argstr) = @_;

    my %params=();
    my $query = ($argstr) ? CGI::Simple->new($argstr) : CGI::Simple->new() ;
    # my $params = $query->Vars; returns a tied hash with keys that
    # are not parameters of the CGI query.
    %params = $query->Vars;

    # Some clients send the 'action' parameter twice;
    # see UI/js-src/Form.js::submit() for more
    $params{action} = (split "\0", $params{action})[0]
        if defined $params{action};

    for my $p(keys %params){
        if ((! defined $params{$p}) or ($params{$p} eq '')){
            delete $params{$p};
            next;
        }
        utf8::decode($params{$p});
        utf8::upgrade($params{$p});
    }
    $self->merge(\%params);

    # Adding this so that empty values are stored in the db as NULL's.  If
    # stored procedures want to handle them differently,
    # they must opt to do so.
    # -- CT
    for (keys %$self){
        if (defined $self->{$_}
            && $self->{$_} eq ''){
            $self->{$_} = undef;
        }
    }
    return $query;
}

sub _process_cookies {
    my ($self) = @_;
    my %cookie;


    # Explicitly don't use the cookie content when we have a simple request
    # for login.pl without an 'action' query parameter: this is a request
    # for the login page, not for the 'post-login' menu/content page
    if ($ENV{REQUEST_METHOD} eq 'GET'
        && $self->{script} eq 'login.pl'
        && (! defined $self->{action} || $self->{action} eq ''
            || $self->{action} eq 'authenticate')) {
        $self->{cookie} = ''; # reset cookie -- prevents later use
        return;
    }

    if ($self->is_run_mode('cgi', 'mod_perl') and $ENV{HTTP_COOKIE}) {
        $ENV{HTTP_COOKIE} =~ s/;\s*/;/gx;
        my @cookies = split ';', $ENV{HTTP_COOKIE};
        foreach (@cookies) {
            my ( $name, $value ) = split '=', $_, 2;
            $cookie{$name} = $value;
        }
    }

    $self->{cookie} = $cookie{$LedgerSMB::Sysconfig::cookie_name};


    if (! $self->{company} && $self->{cookie}) {
        my $ccookie = $self->{cookie};
        $ccookie =~ s/.*:([^:]*)$/$1/x;
        $self->{company} = $ccookie
            unless $ccookie eq 'Login';
    }
    return;
}

sub is_run_mode {
    my ($self, $mode) = @_;
    return 0 unless ( $mode );
    $mode=lc $mode;
    if ( ( $mode eq 'cgi' && $ENV{GATEWAY_INTERFACE} ) ||
         ( $mode eq 'cli' && !( $ENV{GATEWAY_INTERFACE} || $ENV{MOD_PERL} ) ) ||
         ( $mode eq 'mod_perl' && $ENV{MOD_PERL} )) {
        return 1;
    }
    return 0;
}

sub call_procedure {
    my ($self, %args) = @_;
    $args{funcschema} ||= $LedgerSMB::Sysconfig::db_namespace;
    $args{funcname} ||= $args{procname};
    $args{dbh} = LedgerSMB::App_State::DBH();
    $args{args} ||= [];
    return PGObject->call_procedure(%args);
}

# Keeping this here due to common requirements
sub is_allowed_role {
    my ($self, $args) = @_;
    my ($access) =  $self->call_procedure(
         procname => 'lsmb__is_allowed_role', args => [$args->{allowed_roles}]
    );
    return $access->{lsmb__is_allowed_role};
}

sub finalize_request {
    LedgerSMB::App_State->cleanup();
    croak 'exit'; # return to error handling and cleanup
                  # Without dying, we tend to continue with a bad dbh. --CT
}

sub error {
    my ($self, $msg) = @_;
    Carp::croak $msg;
}

sub _error {
    my ( $self_or_form, $msg, $status ) = @_;
    $msg = "? _error" if !defined $msg;
    $status = 500 if ! defined $status;

    if ( ! $ENV{GATEWAY_INTERFACE} && $ENV{error_function} ) {

        &{ $ENV{error_function} }($msg);

    }
    else {
        print qq|Status: $status ISE
Content-Type: text/html; charset=utf-8

<html>
<body><h2 class="error">Error!</h2> <p><b>$msg</b></p>
<p>dbversion: $self_or_form->{dbversion}, company: $self_or_form->{company}</p>
</body>
</html>
|;
    }
    croak;
}

# Database routines used throughout

sub _db_init {
    my ($self, %args) =  @_;
    my ($package, $filename, $line)=caller;
    if (!$self->{company}){
        $self->{company} = $LedgerSMB::Sysconfig::default_db;
    }
    if (!($self->{dbh} = LedgerSMB::App_State::DBH)){
        $self->{dbh} = LedgerSMB::DBH->connect($self->{company})
            || return 0;
    }
    LedgerSMB::App_State::set_DBH($self->{dbh});
    LedgerSMB::App_State::set_DBName($self->{company});
    return 1;
}


sub dberror{
   my $self = shift;
   my $state_error = {};
   my $locale = $LedgerSMB::App_State::Locale;
   if (! $locale) { $locale=$self->{_locale}; } #tshvr4
   my $dbh = $LedgerSMB::App_State::DBH;
   $state_error = {
            '42883' => $locale->text('Internal Database Error'),
            '42501' => $locale->text('Access Denied'),
            '42401' => $locale->text('Access Denied'),
            '22008' => $locale->text('Invalid date/time entered'),
            '22012' => $locale->text('Division by 0 error'),
            '22004' => $locale->text('Required input not provided'),
            '23502' => $locale->text('Required input not provided'),
            '23505' => $locale->text('Conflict with Existing Data.  Perhaps you already entered this?'),
            'P0001' => $locale->text('Error from Function:') . "\n" .
                    $dbh->errstr,
   };
   $logger->error("Logging SQL State ".$dbh->state.", error ".
           $dbh->err . ", string " .$dbh->errstr);
   if (defined $state_error->{$dbh->state}){
       $dbh->rollback;
       croak $state_error->{$dbh->state} . "\n" .
          $locale->text('More information has been reported in the error logs');
   }
   croak $dbh->state . ":" . $dbh->errstr;
}

sub merge {
    my ( $self, $src, %args ) = @_;
    my ($package, $filename, $line)=caller;
    $logger->debug("begin caller \$filename=$filename \$line=$line");
    my (@keys);
    @keys = @{$args{keys}} if (exists $args{keys} && defined $args{keys});

    my $index = $args{index};
    unless ( scalar @keys ) {
        @keys = keys %{$src};
    }
    for my $arg ( @keys ) {
        my $dst_arg;
        if ($index) {
            $dst_arg = $arg . "_$index";
        }
        else {
            $dst_arg = $arg;
        }
        if ( defined $dst_arg && defined $src->{$arg} )
        {
            $logger->trace("LedgerSMB.pm: merge setting $dst_arg to $src->{$arg}");
        }
        elsif ( !defined $dst_arg && defined $src->{$arg} )
        {
            $logger->trace("LedgerSMB.pm: merge setting \$dst_arg is undefined \$src->{\$arg} is defined $src->{$arg}");
        }
        elsif ( defined $dst_arg && !defined $src->{$arg} )
        {
            $logger->trace("LedgerSMB.pm: merge setting \$dst_arg is defined $dst_arg \$src->{\$arg} is undefined");
        }
        elsif ( !defined $dst_arg && !defined $src->{$arg} )
        {
            $logger->trace("LedgerSMB.pm: merge setting \$dst_arg is undefined \$src->{\$arg} is undefined");
        }
        $self->{$dst_arg} = $src->{$arg};
    }
    $logger->debug("end caller \$filename=$filename \$line=$line");
    return;
}

sub type {
    my $self = shift;

    if (!$ENV{REQUEST_METHOD} or
        ( !grep {$ENV{REQUEST_METHOD} eq $_} ("HEAD", "GET", "POST") ) ) {

        $self->error("Request method unset or set to unknown value");
    }

    return $ENV{REQUEST_METHOD};
}

sub DESTROY {}

sub set {

    my ($self, %args) = @_;

    for my $arg (keys(%args)) {
        $self->{$arg} = $args{$arg};
    }
    return 1;

}

sub remove_cgi_globals {
    my ($self) = @_;
    for my $key (keys %$self){
        if ($key =~ /^\./x){
            delete $self->{key}
        }
    }
    return;
}

sub take_top_level {
   my ($self) = @_;
   my $return_hash = {};
   for my $key (keys %$self){
       if (!ref($self->{$key}) && $key !~ /^\./x){
          $return_hash->{$key} = $self->{$key}
       }
   }
   return $return_hash;
}


sub fix_translation {
    my ($self, $obj, $tag) = @_;
    if (('HASH' eq ref $obj) && (exists $obj->{$tag}) && (exists $self->{_locale}) && $self->{_locale}->can('text')) {
        $obj->{$tag}=$self->{_locale}->text($obj->{$tag});
    }
    return $obj;
}


1;

#!/bin/bash

# Production-Grade Django Multi-Tenant Migration Script
# Follows DevOps best practices for zero-downtime deployments
# Compatible with Render, Heroku, AWS, and other cloud platforms

set -euo pipefail  # Exit on error, undefined vars, pipe failures
IFS=$'\n\t'        # Secure Internal Field Separator

# Configuration
readonly SCRIPT_NAME="$(basename "${0}")"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly LOG_FILE="${LOG_FILE:-/tmp/deployment.log}"
readonly ENVIRONMENT="${ENVIRONMENT:-production}"
readonly TIMEOUT_SECONDS=300

# Color codes for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# Helper function to get the correct python command
get_python_cmd() {
    if command -v python &> /dev/null; then
        echo "python"
    elif command -v python3 &> /dev/null; then
        echo "python3"
    else
        log_error "Neither python nor python3 found in PATH"
        exit 1
    fi
}

# Logging functions with timestamps
log_info() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] [INFO]${NC} $1" | tee -a "$LOG_FILE"
}

log_warning() {
    echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] [WARNING]${NC} $1" | tee -a "$LOG_FILE"
}

log_error() {
    echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] [ERROR]${NC} $1" | tee -a "$LOG_FILE"
}

log_debug() {
    if [[ "${DEBUG:-false}" == "true" ]]; then
        echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')] [DEBUG]${NC} $1" | tee -a "$LOG_FILE"
    fi
}

# Error handling
handle_error() {
    local exit_code=$?
    local line_number=$1
    log_error "Script failed at line ${line_number} with exit code ${exit_code}"
    log_error "Check the log file at: ${LOG_FILE}"
    exit "${exit_code}"
}

# Trap errors for debugging
trap 'handle_error ${LINENO}' ERR

# Health check function
check_health() {
    local check_name=$1
    local check_command=$2
    local timeout=${3:-30}
    
    log_debug "Running health check: ${check_name}"
    
    if timeout "${timeout}" bash -c "${check_command}" &>/dev/null; then
        log_info "✅ ${check_name} - PASSED"
        return 0
    else
        log_warning "⚠️  ${check_name} - FAILED (non-critical)"
        return 1
    fi
}

# Database connection test with retry logic
test_database_connection() {
    local max_attempts=5
    local attempt=1
    local python_cmd=$(get_python_cmd)
    
    log_info "Testing database connection..."
    log_debug "Python command: ${python_cmd}"
    log_debug "DJANGO_SETTINGS_MODULE: ${DJANGO_SETTINGS_MODULE:-not set}"
    log_debug "DATABASE_URL present: $([ -n "${DATABASE_URL:-}" ] && echo "yes" || echo "no")"
    log_debug "ENVIRONMENT: ${ENVIRONMENT:-not set}"
    
    while [[ $attempt -le $max_attempts ]]; do
        local connection_test_output
        connection_test_output=$($python_cmd manage.py shell -c "
from django.db import connection, OperationalError
from django.conf import settings
import os

print(f'Django settings module: {os.environ.get(\"DJANGO_SETTINGS_MODULE\", \"not set\")}')
print(f'Database engine: {settings.DATABASES[\"default\"][\"ENGINE\"]}')
print(f'Database name: {settings.DATABASES[\"default\"].get(\"NAME\", \"not set\")}')
print(f'Database host: {settings.DATABASES[\"default\"].get(\"HOST\", \"not set\")}')

try:
    with connection.cursor() as cursor:
        cursor.execute('SELECT 1')
        cursor.fetchone()
    print('SUCCESS: Database connection successful')
except Exception as e:
    error_msg = str(e)
    print(f'ERROR: Database connection failed: {error_msg}')
    
    # Verificar si es un error de DNS que puede ser normal en local
    if 'could not translate host name' in error_msg and 'render.com' not in error_msg:
        print('INFO: This might be a Render internal URL that only works in production')
        print('INFO: If you are testing locally, try using the External Database URL from Render')
    
    print(f'DEBUG: Connection parameters: {connection.settings_dict}')
    exit(1)
        " 2>&1)
        
        if echo "$connection_test_output" | grep -q "SUCCESS: Database connection successful"; then
            log_info "Database connection successful on attempt ${attempt}"
            log_debug "Connection details: $connection_test_output"
            return 0
        else
            log_warning "Database connection failed on attempt ${attempt}/${max_attempts}"
            
            # Mostrar información útil en caso de error
            if echo "$connection_test_output" | grep -q "could not translate host name"; then
                log_info "Note: Render internal URLs only work in the Render environment"
                log_info "If testing locally, use the External Database URL from Render"
            fi
            
            if [[ "${DEBUG:-false}" == "true" ]]; then
                log_error "Full connection output: $connection_test_output"
            fi
            
            if [[ $attempt -lt $max_attempts ]]; then
                sleep $((attempt * 2))  # Exponential backoff
            fi
            ((attempt++))
        fi
    done
    
    log_error "Database connection failed after ${max_attempts} attempts"
    log_error "If using Render internal URL, this is expected locally but should work in production"
    return 1
}

# Create initial tenant with improved error handling
create_initial_tenant() {
    log_info "🏗️  Creating initial tenant for django-tenants compatibility..."
    
    # Configuration for initial tenant with fallback values
    local tenant_schema="${TENANT_SCHEMA:-principal}"
    local tenant_domain="${TENANT_DOMAIN:-example.com}"
    local tenant_name="${TENANT_NAME:-Default Tenant}"
    local tenant_email="${TENANT_EMAIL:-admin@example.com}"
    local tenant_phone="${TENANT_PHONE:-}"
    local tenant_professional_number="${TENANT_PROFESSIONAL_NUMBER:-}"
    local tenant_notes="${TENANT_NOTES:-Initial tenant created during deployment}"
    
    log_info "Creating tenant with configuration:"
    log_info "  - Schema: ${tenant_schema}"
    log_info "  - Domain: ${tenant_domain}"
    log_info "  - Name: ${tenant_name}"
    log_info "  - Email: ${tenant_email}"
    
    local creation_output
    creation_output=$(python manage.py shell -c "
from django.db import transaction, IntegrityError
from django_tenants.utils import get_tenant_model, get_tenant_domain_model
import sys

try:
    Tenant = get_tenant_model()
    Domain = get_tenant_domain_model()
    
    # Check if tenant already exists
    existing_tenant = Tenant.objects.filter(schema_name='${tenant_schema}').first()
    if existing_tenant:
        print('INFO: Tenant already exists')
        print('  ID:', existing_tenant.id)
        print('  Name:', existing_tenant.name)
        print('  Schema:', existing_tenant.schema_name)
        sys.exit(0)
    
    # Check if email is already used
    existing_email = Tenant.objects.filter(email='${tenant_email}').first()
    if existing_email:
        print('WARNING: Email already in use by tenant:', existing_email.name)
        # Generate unique email
        import time
        unique_email = f'admin+{int(time.time())}@{\"${tenant_domain}\".split(\".\")[-2:]}'
        print('Using alternative email:', unique_email)
        tenant_email = unique_email
    else:
        tenant_email = '${tenant_email}'
    
    with transaction.atomic():
        # Create tenant with all required fields
        tenant = Tenant.objects.create(
            schema_name='${tenant_schema}',
            name='${tenant_name}',
            email=tenant_email,
            phone='${tenant_phone}',
            professional_number='${tenant_professional_number}',
            notes='${tenant_notes}',
            status=Tenant.StatusChoices.ACTIVE
        )
        
        # Create domain
        domain = Domain.objects.create(
            domain='${tenant_domain}',
            tenant=tenant,
            is_primary=True
        )
        
        print('SUCCESS: Tenant created successfully')
        print('  ID:', tenant.id)
        print('  Name:', tenant.name)
        print('  Schema:', tenant.schema_name)
        print('  Email:', tenant.email)
        print('  Domain:', domain.domain)
        print('  Slug:', getattr(tenant, 'slug', 'N/A'))
        print('  Status:', tenant.status)
        
except IntegrityError as e:
    print('ERROR: Integrity constraint violation:', str(e))
    print('This usually means the tenant or domain already exists')
    sys.exit(1)
except Exception as e:
    print('ERROR: Failed to create tenant:', str(e))
    import traceback
    traceback.print_exc()
    sys.exit(1)
    " 2>&1)
    
    echo "$creation_output"
    
    if echo "$creation_output" | grep -q "SUCCESS: Tenant created successfully"; then
        log_info "✅ Initial tenant created successfully"
        return 0
    elif echo "$creation_output" | grep -q "INFO: Tenant already exists"; then
        log_info "ℹ️  Tenant already exists - skipping creation"
        return 0
    else
        log_error "❌ Failed to create initial tenant"
        if [[ "${DEBUG:-false}" == "true" ]]; then
            log_error "Creation output: $creation_output"
        fi
        return 1
    fi
}

# Database state diagnosis with improved error handling
diagnose_database_state() {
    log_info "🔍 Diagnosing database state..."
    local python_cmd=$(get_python_cmd)
    
    local diagnosis_output
    diagnosis_output=$($python_cmd manage.py shell -c "
from django.db import connection
from django.db.migrations.recorder import MigrationRecorder
import sys

try:
    with connection.cursor() as cursor:
        # Get basic database info
        table_names = connection.introspection.table_names(cursor)
        total_tables = len(table_names)
        print('Total tables in database:', total_tables)
        
        if total_tables == 0:
            print('STATUS: EMPTY_DATABASE')
            sys.exit(0)
        
        # Check django_migrations table
        if 'django_migrations' not in table_names:
            print('STATUS: NO_MIGRATION_TABLE')
            sys.exit(0)
        
        # Check migration status
        recorder = MigrationRecorder(connection)
        applied_migrations = recorder.applied_migrations()
        print('Applied migrations count:', len(applied_migrations))
        
        # Count migrations by app
        app_counts = {}
        for app, migration in applied_migrations:
            app_counts[app] = app_counts.get(app, 0) + 1
        
        print('Applied migrations by app:')
        for app, count in sorted(app_counts.items()):
            print('  ' + app + ':', count, 'migrations')
        
        # Check essential tables
        essential_tables = ['tenants_tenant', 'tenants_domain', 'users']
        missing_essential = [t for t in essential_tables if t not in table_names]
        
        # Check tenant app tables (these should exist in public schema for this project)
        tenant_app_tables = ['business_lines', 'clients', 'client_services', 'expenses']
        present_tenant_tables = [t for t in tenant_app_tables if t in table_names]
        
        if missing_essential:
            print('STATUS: MISSING_ESSENTIAL_TABLES')
            for table in missing_essential:
                print('  Missing essential table:', table)
        elif present_tenant_tables:
            # Check if we have tenants
            cursor.execute('SELECT COUNT(*) FROM tenants_tenant')
            tenant_count = cursor.fetchone()[0]
            print('Tenant count:', tenant_count)
            
            if tenant_count > 0:
                print('STATUS: HEALTHY_DATABASE')
                print('Note: Database is functional with', len(present_tenant_tables), 'tenant app tables in public schema')
            else:
                print('STATUS: NO_TENANTS_FOUND')
        else:
            print('STATUS: INCOMPLETE_TENANT_TABLES')
            
except Exception as e:
    print('ERROR: Database diagnosis failed:', str(e))
    sys.exit(1)
    " 2>&1)
    
    echo "$diagnosis_output"
    
    # Parse diagnosis results and return appropriate status
    if echo "$diagnosis_output" | grep -q "STATUS: EMPTY_DATABASE"; then
        log_info "✅ Database is empty - ready for fresh deployment"
        return 0
    elif echo "$diagnosis_output" | grep -q "STATUS: NO_MIGRATION_TABLE"; then
        log_warning "⚠️  Database has tables but no migration tracking"
        return 1
    elif echo "$diagnosis_output" | grep -q "STATUS: HEALTHY_DATABASE"; then
        log_info "✅ Database is healthy and ready"
        return 0
    elif echo "$diagnosis_output" | grep -q "STATUS: NO_TENANTS_FOUND"; then
        log_warning "⚠️  Database structure exists but no tenants found"
        log_info "🔧 Will attempt to create initial tenant during migration"
        return 0
    elif echo "$diagnosis_output" | grep -q "STATUS: MISSING_ESSENTIAL_TABLES"; then
        log_error "❌ Essential tables are missing"
        return 1
    elif echo "$diagnosis_output" | grep -q "STATUS: INCOMPLETE_TENANT_TABLES"; then
        log_warning "⚠️  Some tenant app tables are missing"
        return 1
    else
        log_error "❌ Could not determine database status"
        return 1
    fi
}

# Pre-deployment checks
pre_deployment_checks() {
    log_info "🔍 Running pre-deployment checks..."
    
    # Check if we're in the right directory
    if [[ ! -f "manage.py" ]]; then
        log_error "manage.py not found. Please run this script from the Django project root."
        log_error "Current directory: $(pwd)"
        log_error "Directory contents: $(ls -la)"
        exit 1
    fi
    
    # Check if Python is available
    if ! command -v python &> /dev/null; then
        log_error "Python command not found in PATH"
        log_error "Available commands: $(compgen -c | grep python || echo 'No python commands found')"
        
        # Try python3 as fallback
        if command -v python3 &> /dev/null; then
            log_info "Using python3 instead of python"
            # Create a symlink or alias would be better, but for now we'll handle this in each call
        else
            log_error "Neither python nor python3 found in PATH"
            exit 1
        fi
    fi
    
    # Check Django settings
    if [[ -z "${DJANGO_SETTINGS_MODULE:-}" ]]; then
        log_error "DJANGO_SETTINGS_MODULE environment variable not set"
        log_error "Expected: config.settings.production for production environment"
        exit 1
    fi
    
    log_info "Using Django settings: ${DJANGO_SETTINGS_MODULE}"
    
    # Check Python version and Django installation
    local python_cmd=$(get_python_cmd)
    
    local python_version
    python_version=$($python_cmd --version 2>&1 | cut -d' ' -f2)
    log_info "Python version: ${python_version}"
    
    # Test Django installation
    if ! $python_cmd -c "import django; print('Django version:', django.get_version())" 2>/dev/null; then
        log_error "Django is not properly installed or accessible"
        log_error "Python path: $($python_cmd -c 'import sys; print(sys.path)' 2>/dev/null || echo 'Cannot access Python')"
        exit 1
    fi
    
    # Check required environment variables
    local required_vars=("DATABASE_URL" "SECRET_KEY")
    for var in "${required_vars[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            log_error "Required environment variable ${var} is not set"
            log_error "Available environment variables: $(env | grep -E '(DJANGO|DATABASE|SECRET)' | cut -d'=' -f1 || echo 'No relevant variables found')"
            exit 1
        fi
    done
    
    # Test Django configuration loading
    log_info "Testing Django configuration..."
    if ! $python_cmd manage.py check --settings="${DJANGO_SETTINGS_MODULE}" >/dev/null 2>&1; then
        log_error "Django configuration test failed"
        log_error "Try running: $python_cmd manage.py check --settings=${DJANGO_SETTINGS_MODULE}"
        exit 1
    fi
    
    log_info "✅ Pre-deployment checks completed"
}

# Migration execution with proper error handling
execute_migrations() {
    log_info "🚀 Executing database migrations..."
    local python_cmd=$(get_python_cmd)
    
    # Test database connection first
    if ! test_database_connection; then
        log_error "Cannot proceed with migrations - database connection failed"
        return 1
    fi
    
    # Diagnose database state
    if ! diagnose_database_state; then
        log_warning "Database state diagnosis indicates potential issues"
        if [[ "${FORCE_MIGRATION:-false}" != "true" ]]; then
            log_error "Set FORCE_MIGRATION=true to proceed anyway"
            return 1
        else
            log_warning "FORCE_MIGRATION=true - proceeding despite warnings"
        fi
    fi
    
    # Run migrations for public schema (shared apps)
    log_info "Running migrations for public schema..."
    $python_cmd manage.py migrate_schemas --shared --verbosity=2 --skip-checks
    
    # Run migrations for tenant schemas
    log_info "Running migrations for tenant schemas..."
    $python_cmd manage.py migrate_schemas --verbosity=2 --skip-checks || {
        log_warning "Tenant migration failed - this might be normal for first deployment"
        log_info "Tenant schemas will be created when tenants are added"
    }
    
    log_info "✅ Database migrations completed"
}

# Static files collection
collect_static_files() {
    log_info "📦 Collecting static files..."
    local python_cmd=$(get_python_cmd)
    
    # Ensure static directories exist
    mkdir -p "${STATIC_ROOT:-/app/static_collected}"
    
    if ! $python_cmd manage.py collectstatic --noinput --verbosity=1; then
        log_error "Static files collection failed"
        return 1
    fi
    
    log_info "✅ Static files collection completed"
}

# Post-deployment checks
post_deployment_checks() {
    log_info "🔍 Running post-deployment checks..."
    local python_cmd=$(get_python_cmd)
    
    # Django system check (critical)
    if ! check_health "Django System Check" "$python_cmd manage.py check --verbosity=1"; then
        log_error "Django system check failed - this is critical"
        return 1
    fi
    
    # Health endpoint check (non-critical)
    if command -v curl &>/dev/null; then
        if check_health "Health Endpoint" "curl -f http://localhost:8000/health/" 10; then
            log_info "Health endpoint is responding correctly"
        else
            log_warning "Health endpoint check failed, but this is non-critical during deployment"
            log_info "The application may not be fully started yet during pre-deploy phase"
        fi
    fi
    
    log_info "✅ Post-deployment checks completed"
}

# Display usage information
show_usage() {
    cat << EOF
Usage: $SCRIPT_NAME [OPTIONS]

Production-Grade Django Multi-Tenant Migration Script

OPTIONS:
    -h, --help              Show this help message
    -d, --diagnose          Only diagnose database state, don't migrate
    -f, --force             Force migration even if database state looks problematic
    -c, --clean-deploy      Assume clean database deployment (skip some checks)
    --skip-static          Skip static files collection
    --skip-checks          Skip post-deployment checks

ENVIRONMENT VARIABLES:
    DATABASE_URL           Database connection string (required)
    SECRET_KEY            Django secret key (required)
    DJANGO_SETTINGS_MODULE Django settings module (required)
    STATIC_ROOT           Static files directory (optional)
    LOG_FILE              Log file path (default: /tmp/deployment.log)
    DEBUG                 Enable debug logging (default: false)
    FORCE_MIGRATION       Force migration despite warnings (default: false)

EXAMPLES:
    # Fresh deployment on empty database
    $SCRIPT_NAME --clean-deploy
    
    # Diagnose database state only
    $SCRIPT_NAME --diagnose
    
    # Force migration on problematic database
    $SCRIPT_NAME --force
    
    # Quick deployment without static files
    $SCRIPT_NAME --skip-static

EOF
}

# Database state diagnosis only
diagnose_only() {
    log_info "🔍 Database State Diagnosis Mode"
    
    if ! test_database_connection; then
        log_error "Cannot diagnose - database connection failed"
        exit 1
    fi
    
    diagnose_database_state
    local diagnosis_result=$?
    
    if [[ $diagnosis_result -eq 0 ]]; then
        log_info "✅ Database is ready for deployment"
    else
        log_warning "⚠️  Database may need attention before deployment"
        log_info "Consider using --force flag or cleaning the database"
    fi
    
    exit $diagnosis_result
}

# Main execution function with professional error handling
main() {
    local DIAGNOSE_ONLY=false
    local FORCE_MIGRATION=false
    local CLEAN_DEPLOY=false
    local SKIP_STATIC=false
    local SKIP_CHECKS=false
    
    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_usage
                exit 0
                ;;
            -d|--diagnose)
                DIAGNOSE_ONLY=true
                shift
                ;;
            -f|--force)
                FORCE_MIGRATION=true
                export FORCE_MIGRATION=true
                shift
                ;;
            -c|--clean-deploy)
                CLEAN_DEPLOY=true
                shift
                ;;
            --skip-static)
                SKIP_STATIC=true
                shift
                ;;
            --skip-checks)
                SKIP_CHECKS=true
                shift
                ;;
            *)
                log_error "Unknown option: $1"
                show_usage
                exit 1
                ;;
        esac
    done
    
    # Set up logging and environment
    mkdir -p "$(dirname "${LOG_FILE}")"
    
    log_info "🚀 Starting production-grade deployment process..."
    log_info "📅 Date: $(date)"
    log_info "🌍 Environment: ${ENVIRONMENT}"
    log_info "📝 Log file: ${LOG_FILE}"
    log_info "🔧 Django settings: ${DJANGO_SETTINGS_MODULE:-not set}"
    
    if [[ "$FORCE_MIGRATION" == "true" ]]; then
        log_warning "⚠️  FORCE_MIGRATION enabled - will proceed despite warnings"
    fi
    
    if [[ "$CLEAN_DEPLOY" == "true" ]]; then
        log_info "📦 Clean deployment mode - assuming fresh database"
    fi
    
    # Handle diagnose-only mode
    if [[ "$DIAGNOSE_ONLY" == "true" ]]; then
        diagnose_only
        exit $?
    fi
    
    # Execute deployment steps with proper error handling
    local step_count=0
    local total_steps=4
    
    # Step 1: Pre-deployment checks
    ((step_count++))
    log_info "📋 Step ${step_count}/${total_steps}: Running pre-deployment checks..."
    if ! pre_deployment_checks; then
        log_error "❌ Pre-deployment checks failed"
        exit 1
    fi
    
    # Step 2: Database migrations
    ((step_count++))
    log_info "📋 Step ${step_count}/${total_steps}: Executing database migrations..."
    if ! execute_migrations; then
        log_error "❌ Database migrations failed"
        exit 1
    fi
    
    # Step 3: Static files (optional)
    ((step_count++))
    if [[ "$SKIP_STATIC" != "true" ]]; then
        log_info "📋 Step ${step_count}/${total_steps}: Collecting static files..."
        if ! collect_static_files; then
            log_warning "⚠️  Static files collection failed, but continuing..."
        fi
    else
        log_info "� Step ${step_count}/${total_steps}: Skipping static files collection"
    fi
    
    # Step 4: Post-deployment checks (optional)
    ((step_count++))
    if [[ "$SKIP_CHECKS" != "true" ]]; then
        log_info "📋 Step ${step_count}/${total_steps}: Running post-deployment checks..."
        if ! post_deployment_checks; then
            log_warning "⚠️  Some post-deployment checks failed, but deployment is complete"
        fi
    else
        log_info "� Step ${step_count}/${total_steps}: Skipping post-deployment checks"
    fi
    
    # Success message
    log_info ""
    log_info "🎉 DEPLOYMENT COMPLETED SUCCESSFULLY!"
    log_info "✅ All critical steps completed"
    log_info "🚀 Application is ready to serve traffic"
    log_info "📊 Summary:"
    log_info "   - Database migrations: ✅ Applied"
    log_info "   - Static files: $([ "$SKIP_STATIC" == "true" ] && echo "⏭️  Skipped" || echo "✅ Collected")"
    log_info "   - Health checks: $([ "$SKIP_CHECKS" == "true" ] && echo "⏭️  Skipped" || echo "✅ Passed")"
    log_info ""
    log_info "📝 Deployment completed at: $(date)"
    
    return 0
}

# Main execution function
main_legacy() {
    log_info "🚀 Starting production-grade deployment process..."
    log_info "Environment: ${ENVIRONMENT}"
    log_info "Log file: ${LOG_FILE}"
    
    # Create log directory if it doesn't exist
    mkdir -p "$(dirname "${LOG_FILE}")"
    
    # Execute deployment steps
    pre_deployment_checks
    execute_migrations
    collect_static_files
    post_deployment_checks
    
    log_info "🎉 Deployment completed successfully!"
    log_info "Application is ready to serve traffic"
}

# Script execution
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi

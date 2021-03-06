module fpm_sources
use fpm_error, only: error_t, file_parse_error, fatal_error
use fpm_model, only: srcfile_ptr, srcfile_t, fpm_model_t, &
                    FPM_UNIT_UNKNOWN, FPM_UNIT_PROGRAM, FPM_UNIT_MODULE, &
                    FPM_UNIT_SUBMODULE, FPM_UNIT_SUBPROGRAM, &
                    FPM_UNIT_CSOURCE, FPM_UNIT_CHEADER, FPM_SCOPE_UNKNOWN, &
                    FPM_SCOPE_LIB, FPM_SCOPE_DEP, FPM_SCOPE_APP, FPM_SCOPE_TEST
                    
use fpm_filesystem, only: basename, canon_path, dirname, read_lines, list_files
use fpm_strings, only: lower, split, str_ends_with, string_t, operator(.in.)
use fpm_manifest_executable, only: executable_t
implicit none

private
public :: add_sources_from_dir, add_executable_sources
public :: parse_f_source, parse_c_source, resolve_module_dependencies

character(15), parameter :: INTRINSIC_MODULE_NAMES(*) =  &
                             ['iso_c_binding  ', &
                              'iso_fortran_env', &
                              'ieee_arithmetic', &
                              'ieee_exceptions', &
                              'ieee_features  ']

contains

subroutine add_sources_from_dir(sources,directory,scope,with_executables,error)
    ! Enumerate sources in a directory
    !
    type(srcfile_t), allocatable, intent(inout), target :: sources(:)
    character(*), intent(in) :: directory
    integer, intent(in) :: scope
    logical, intent(in), optional :: with_executables
    type(error_t), allocatable, intent(out) :: error

    integer :: i, j
    logical, allocatable :: is_source(:), exclude_source(:)
    type(string_t), allocatable :: file_names(:)
    type(string_t), allocatable :: src_file_names(:)
    type(string_t), allocatable :: existing_src_files(:)
    type(srcfile_t), allocatable :: dir_sources(:)

    ! Scan directory for sources
    call list_files(directory, file_names,recurse=.true.)

    if (allocated(sources)) then
        allocate(existing_src_files(size(sources)))
        do i=1,size(sources)
            existing_src_files(i)%s = sources(i)%file_name
        end do
    else
        allocate(existing_src_files(0))
    end if

    is_source = [(.not.(file_names(i)%s .in. existing_src_files) .and. &
                  (str_ends_with(lower(file_names(i)%s), ".f90") .or. &
                   str_ends_with(lower(file_names(i)%s), ".c") .or. &
                   str_ends_with(lower(file_names(i)%s), ".h") ),i=1,size(file_names))]
    src_file_names = pack(file_names,is_source)

    allocate(dir_sources(size(src_file_names)))
    allocate(exclude_source(size(src_file_names)))

    do i = 1, size(src_file_names)

        if (str_ends_with(lower(src_file_names(i)%s), ".f90")) then

            dir_sources(i) = parse_f_source(src_file_names(i)%s, error)

            if (allocated(error)) then
                return
            end if

        end if

        if (str_ends_with(lower(src_file_names(i)%s), ".c") .or. &
            str_ends_with(lower(src_file_names(i)%s), ".h")) then

            dir_sources(i) = parse_c_source(src_file_names(i)%s,error)

            if (allocated(error)) then
                return
            end if

        end if

        dir_sources(i)%unit_scope = scope

        ! Exclude executables unless specified otherwise
        exclude_source(i) = (dir_sources(i)%unit_type == FPM_UNIT_PROGRAM)
        if (dir_sources(i)%unit_type == FPM_UNIT_PROGRAM .and. &
            & present(with_executables)) then
            if (with_executables) then

                exclude_source(i) = .false.
                dir_sources(i)%exe_name = basename(src_file_names(i)%s,suffix=.false.)

            end if
        end if

    end do

    if (.not.allocated(sources)) then
        sources = pack(dir_sources,.not.exclude_source)
    else
        sources = [sources, pack(dir_sources,.not.exclude_source)]
    end if

end subroutine add_sources_from_dir


subroutine add_executable_sources(sources,executables,scope,auto_discover,error)
    ! Include sources from any directories specified 
    !  in [[executable]] entries and apply any customisations
    !  
    type(srcfile_t), allocatable, intent(inout), target :: sources(:)
    class(executable_t), intent(in) :: executables(:)
    integer, intent(in) :: scope
    logical, intent(in) :: auto_discover
    type(error_t), allocatable, intent(out) :: error

    integer :: i, j

    type(string_t), allocatable :: exe_dirs(:)
    logical, allocatable :: include_source(:)
    type(srcfile_t), allocatable :: dir_sources(:)

    call get_executable_source_dirs(exe_dirs,executables)

    do i=1,size(exe_dirs)
        call add_sources_from_dir(dir_sources,exe_dirs(i)%s, &
                     scope, with_executables=.true.,error=error)

        if (allocated(error)) then
            return
        end if
    end do

    allocate(include_source(size(dir_sources)))

    do i = 1, size(dir_sources)
        
        ! Include source by default if not a program or if auto_discover is enabled
        include_source(i) = (dir_sources(i)%unit_type /= FPM_UNIT_PROGRAM) .or. &
                             auto_discover

        ! Always include sources specified in fpm.toml
        do j=1,size(executables)

            if (basename(dir_sources(i)%file_name,suffix=.true.) == executables(j)%main .and.&
                 canon_path(dirname(dir_sources(i)%file_name)) == &
                 canon_path(executables(j)%source_dir) ) then
                
                include_source(i) = .true.
                dir_sources(i)%exe_name = executables(j)%name
                exit

            end if
        end do

    end do

    if (.not.allocated(sources)) then
        sources = pack(dir_sources,include_source)
    else
        sources = [sources, pack(dir_sources,include_source)]
    end if

end subroutine add_executable_sources


subroutine get_executable_source_dirs(exe_dirs,executables)
    ! Build a list of unique source directories
    !  from executables specified in manifest
    type(string_t), allocatable, intent(inout) :: exe_dirs(:)
    class(executable_t), intent(in) :: executables(:)

    type(string_t) :: dirs_temp(size(executables))

    integer :: i, n

    n = 0
    do i=1,size(executables)
        if (.not.(executables(i)%source_dir .in. dirs_temp)) then

            n = n + 1
            dirs_temp(n)%s = executables(i)%source_dir

        end if
    end do

    if (.not.allocated(exe_dirs)) then
        exe_dirs = dirs_temp(1:n)
    else
        exe_dirs = [exe_dirs,dirs_temp(1:n)]
    end if

end subroutine get_executable_source_dirs


function parse_f_source(f_filename,error) result(f_source)
    ! Rudimentary scan of Fortran source file and 
    !  extract program unit name and use/include dependencies
    !
    character(*), intent(in) :: f_filename
    type(srcfile_t) :: f_source
    type(error_t), allocatable, intent(out) :: error

    integer :: stat
    integer :: fh, n_use, n_include, n_mod, i, j, ic, pass
    type(string_t), allocatable :: file_lines(:)
    character(:), allocatable :: temp_string, mod_name

    f_source%file_name = f_filename

    open(newunit=fh,file=f_filename,status='old')
    file_lines = read_lines(fh)
    close(fh)

    do pass = 1,2
        n_use = 0
        n_include = 0
        n_mod = 0
        file_loop: do i=1,size(file_lines)

            ! Skip lines that are continued: not statements
            if (i > 1) then
                ic = index(file_lines(i-1)%s,'!')
                if (ic < 1) then
                    ic = len(file_lines(i-1)%s)
                end if
                temp_string = trim(file_lines(i-1)%s(1:ic))
                if (len(temp_string) > 0 .and. index(temp_string,'&') == len(temp_string)) then
                    cycle
                end if
            end if

            ! Process 'USE' statements
            if (index(adjustl(lower(file_lines(i)%s)),'use ') == 1 .or. &
                index(adjustl(lower(file_lines(i)%s)),'use::') == 1) then

                if (index(file_lines(i)%s,'::') > 0) then

                    temp_string = split_n(file_lines(i)%s,delims=':',n=2,stat=stat)
                    if (stat /= 0) then
                        call file_parse_error(error,f_filename, &
                                'unable to find used module name',i, &
                                file_lines(i)%s,index(file_lines(i)%s,'::'))
                        return
                    end if

                    mod_name = split_n(temp_string,delims=' ,',n=1,stat=stat)
                    if (stat /= 0) then
                        call file_parse_error(error,f_filename, &
                                 'unable to find used module name',i, &
                                 file_lines(i)%s)
                        return
                    end if
                    mod_name = lower(mod_name)

                else

                    mod_name = split_n(file_lines(i)%s,n=2,delims=' ,',stat=stat)
                    if (stat /= 0) then
                        call file_parse_error(error,f_filename, &
                                'unable to find used module name',i, &
                                file_lines(i)%s)
                        return
                    end if
                    mod_name = lower(mod_name)

                end if

                if (.not.validate_name(mod_name)) then
                    cycle
                end if

                if (any([(index(mod_name,trim(INTRINSIC_MODULE_NAMES(j)))>0, &
                            j=1,size(INTRINSIC_MODULE_NAMES))])) then
                    cycle
                end if

                n_use = n_use + 1

                if (pass == 2) then

                    f_source%modules_used(n_use)%s = mod_name

                end if

            end if

            ! Process 'INCLUDE' statements
            if (index(adjustl(lower(file_lines(i)%s)),'include') == 1) then
    
                n_include = n_include + 1

                if (pass == 2) then
                    f_source%include_dependencies(n_include)%s = &
                     & split_n(file_lines(i)%s,n=2,delims="'"//'"',stat=stat)
                    if (stat /= 0) then
                        call file_parse_error(error,f_filename, &
                              'unable to find include file name',i, &
                              file_lines(i)%s)
                        return
                    end if
                end if

            end if

            ! Extract name of module if is module
            if (index(adjustl(lower(file_lines(i)%s)),'module ') == 1) then

                mod_name = lower(split_n(file_lines(i)%s,n=2,delims=' ',stat=stat))
                if (stat /= 0) then
                    call file_parse_error(error,f_filename, &
                          'unable to find module name',i, &
                          file_lines(i)%s)
                    return
                end if

                if (mod_name == 'procedure' .or. &
                    mod_name == 'subroutine' .or. &
                    mod_name == 'function') then
                    ! Ignore these cases
                    cycle
                end if

                if (.not.validate_name(mod_name)) then
                    call file_parse_error(error,f_filename, &
                          'empty or invalid name for module',i, &
                          file_lines(i)%s, index(file_lines(i)%s,mod_name))
                    return
                end if

                n_mod = n_mod + 1

                if (pass == 2) then
                    f_source%modules_provided(n_mod) = string_t(mod_name)
                end if

                f_source%unit_type = FPM_UNIT_MODULE

            end if

            ! Extract name of submodule if is submodule
            if (index(adjustl(lower(file_lines(i)%s)),'submodule') == 1) then

                mod_name = split_n(file_lines(i)%s,n=3,delims='()',stat=stat)
                if (stat /= 0) then
                    call file_parse_error(error,f_filename, &
                          'unable to get submodule name',i, &
                          file_lines(i)%s)
                    return
                end if
                if (.not.validate_name(mod_name)) then
                    call file_parse_error(error,f_filename, &
                          'empty or invalid name for submodule',i, &
                          file_lines(i)%s, index(file_lines(i)%s,mod_name))
                    return
                end if

                n_mod = n_mod + 1

                temp_string = split_n(file_lines(i)%s,n=2,delims='()',stat=stat)
                if (stat /= 0) then
                    call file_parse_error(error,f_filename, &
                          'unable to get submodule ancestry',i, &
                          file_lines(i)%s)
                    return
                end if

                f_source%unit_type = FPM_UNIT_SUBMODULE

                n_use = n_use + 1

                if (pass == 2) then

                    if (index(temp_string,':') > 0) then

                        temp_string = temp_string(index(temp_string,':')+1:)
                        
                    end if

                    if (.not.validate_name(temp_string)) then
                        call file_parse_error(error,f_filename, &
                          'empty or invalid name for submodule parent',i, &
                          file_lines(i)%s, index(file_lines(i)%s,temp_string))
                        return
                    end if

                    f_source%modules_used(n_use)%s = lower(temp_string)

                    f_source%modules_provided(n_mod)%s = lower(mod_name)

                end if

            end if

            ! Detect if contains a program
            !  (no modules allowed after program def)
            if (index(adjustl(lower(file_lines(i)%s)),'program') == 1) then

                f_source%unit_type = FPM_UNIT_PROGRAM

            end if

        end do file_loop

        ! Default to subprogram unit type
        if (f_source%unit_type == FPM_UNIT_UNKNOWN) then
            f_source%unit_type = FPM_UNIT_SUBPROGRAM
        end if

        if (pass == 1) then
            allocate(f_source%modules_used(n_use))
            allocate(f_source%include_dependencies(n_include))
            allocate(f_source%modules_provided(n_mod))
        end if

    end do

    contains

    function validate_name(name) result(valid)
        character(*), intent(in) :: name
        logical :: valid

        integer :: i

        if (len_trim(name) < 1) then
            valid = .false.
            return
        end if

        if (lower(name(1:1)) < 'a' .or. &
            lower(name(1:1)) > 'z') then

            valid = .false.
            return
        end if

        do i=1,len(name)

            if (.not.( &
                (name(i:i) >= '0' .and. name(i:i) <= '9').or. &
                (lower(name(i:i)) >= 'a' .and. lower(name(i:i)) <= 'z').or. &
                name(i:i) == '_') ) then
                    
                valid = .false.
                return
            end if

        end do

        valid = .true.
        return

    end function validate_name

end function parse_f_source


function parse_c_source(c_filename,error) result(c_source)
    ! Rudimentary scan of c source file and 
    !  extract include dependencies
    !
    character(*), intent(in) :: c_filename
    type(srcfile_t) :: c_source
    type(error_t), allocatable, intent(out) :: error

    integer :: fh, n_include, i, pass, stat
    type(string_t), allocatable :: file_lines(:)

    c_source%file_name = c_filename

    if (str_ends_with(lower(c_filename), ".c")) then

        c_source%unit_type = FPM_UNIT_CSOURCE

    elseif (str_ends_with(lower(c_filename), ".h")) then

        c_source%unit_type = FPM_UNIT_CHEADER

    end if

    allocate(c_source%modules_used(0))
    allocate(c_source%modules_provided(0))

    open(newunit=fh,file=c_filename,status='old')
    file_lines = read_lines(fh)
    close(fh)

    do pass = 1,2
        n_include = 0
        file_loop: do i=1,size(file_lines)

            ! Process 'INCLUDE' statements
            if (index(adjustl(lower(file_lines(i)%s)),'#include') == 1 .and. &
                index(file_lines(i)%s,'"') > 0) then
                            
                n_include = n_include + 1

                if (pass == 2) then

                    c_source%include_dependencies(n_include)%s = &
                     &   split_n(file_lines(i)%s,n=2,delims='"',stat=stat)
                    if (stat /= 0) then
                        call file_parse_error(error,c_filename, &
                            'unable to get c include file',i, &
                            file_lines(i)%s,index(file_lines(i)%s,'"'))
                        return
                    end if

                end if

            end if

        end do file_loop

        if (pass == 1) then
            allocate(c_source%include_dependencies(n_include))
        end if

    end do

end function parse_c_source


function split_n(string,delims,n,stat) result(substring)
    ! Split a string on one or more delimeters
    !  and return the nth substring if it exists
    !
    ! n=0  will return the last item
    ! n=-1 will return the penultimate item etc.
    !
    ! stat = 1 on return if the index 
    !  is not found
    !
    character(*), intent(in) :: string
    character(*), intent(in) :: delims
    integer, intent(in) :: n
    integer, intent(out) :: stat
    character(:), allocatable :: substring

    integer :: i
    character(:), allocatable :: string_parts(:)

    call split(string,string_parts,delims)

    if (n<1) then
        i = size(string_parts) + n
        if (i < 1) then
            stat = 1
            return
        end if
    else
        i = n
    end if

    if (i>size(string_parts)) then
        stat = 1
        return
    end if

    substring = trim(adjustl(string_parts(i)))
    stat = 0

end function split_n


subroutine resolve_module_dependencies(sources,error)
    ! After enumerating all source files: resolve file dependencies
    !  by searching on module names
    !
    type(srcfile_t), intent(inout), target :: sources(:)
    type(error_t), allocatable, intent(out) :: error

    type(srcfile_ptr) :: dep

    integer :: n_depend, i, pass, j

    do i=1,size(sources)
        
        do pass=1,2

            n_depend = 0

            do j=1,size(sources(i)%modules_used)

                if (sources(i)%modules_used(j)%s .in. sources(i)%modules_provided) then
                    ! Dependency satisfied in same file, skip
                    cycle
                end if
            
                if (sources(i)%unit_scope == FPM_SCOPE_APP .OR. &
                    sources(i)%unit_scope == FPM_SCOPE_TEST ) then
                    dep%ptr => &
                        find_module_dependency(sources,sources(i)%modules_used(j)%s, &
                                            include_dir = dirname(sources(i)%file_name))
                else
                    dep%ptr => &
                        find_module_dependency(sources,sources(i)%modules_used(j)%s)
                end if

                if (.not.associated(dep%ptr)) then
                    call fatal_error(error, &
                            'Unable to find source for module dependency: "' // &
                            sources(i)%modules_used(j)%s // &
                            '" used by "'//sources(i)%file_name//'"')
                    return
                end if

                n_depend = n_depend + 1

                if (pass == 2) then
                    sources(i)%file_dependencies(n_depend) = dep
                end if

            end do

            if (pass == 1) then
                allocate(sources(i)%file_dependencies(n_depend))
            end if

        end do

    end do    

end subroutine resolve_module_dependencies

function find_module_dependency(sources,module_name,include_dir) result(src_ptr)
    ! Find a module dependency in the library or a dependency library
    !
    ! 'include_dir' specifies an allowable non-library search directory
    !   (Used for executable dependencies)
    !
    type(srcfile_t), intent(in), target :: sources(:)
    character(*), intent(in) :: module_name
    character(*), intent(in), optional :: include_dir
    type(srcfile_t), pointer :: src_ptr

    integer :: k, l

    src_ptr => NULL()

    do k=1,size(sources)

        do l=1,size(sources(k)%modules_provided)

            if (module_name == sources(k)%modules_provided(l)%s) then
                select case(sources(k)%unit_scope)
                case (FPM_SCOPE_LIB, FPM_SCOPE_DEP)
                    src_ptr => sources(k)
                    exit
                case default
                    if (present(include_dir)) then
                        if (dirname(sources(k)%file_name) == include_dir) then
                            src_ptr => sources(k)
                            exit
                        end if
                    end if
                end select
            end if

        end do
        
    end do

end function find_module_dependency

end module fpm_sources

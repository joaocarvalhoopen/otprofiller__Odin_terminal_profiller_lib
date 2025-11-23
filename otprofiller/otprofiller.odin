// otprofiller - Odin terminal profiller lib
// 
// Small lib to make a very simple instrumentation profiller in Odin.
// 
// It can be enabled or disabled with a very small hit on the overal performance.
// 
// It generates 2 reports:
// 
//   profiller_report.TXT
//   profiller_report.html  ( this one has a kind of flame graph in it )
//
// 
// Note: At the end of the file there is a small test exampple of its usage.
// 
// 
// License:
// MIT Open Source license


package otprofiller

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import "core:sync"
import "core:thread"
import "core:slice"
import "core:math"
import "core:path/filepath"
import "base:runtime"
import "base:intrinsics"

//
// Configuration
// 

EVENTS_PER_PAGE :: 16384 
MIN_DRAW_NS     :: 50    

//
// Structs
//

Event_Type :: enum u8 { 
    
    Enter,
    Exit
}

Profile_Event :: struct {
    
    kind      : Event_Type,
    tag       : string,                 
    loc       : runtime.Source_Code_Location,
    timestamp : time.Tick,
}

Event_Page :: struct {
    
    events : [ EVENTS_PER_PAGE ]Profile_Event,
    count  :  int,
    next   :   ^Event_Page,
}

Thread_Context :: struct {
    
    tid       : int,
    head_page : ^Event_Page,
    curr_page : ^Event_Page,
}

Global_Registry :: struct {
    
    mutex      : sync.Mutex,
    contexts   : [ dynamic ]^Thread_Context,
    start_time : time.Tick,
    is_enabled : bool,
}

//
// Globals
//

global_registry : Global_Registry

@thread_local
t_context : ^Thread_Context


get_hostname_safe :: proc ( ) -> 
                           string {
                               
    name := os.get_env( "HOSTNAME", context.temp_allocator )
    if len( name ) > 0 {
        
        return name
    }
    name_win := os.get_env( "COMPUTERNAME", context.temp_allocator )
    if len( name_win ) > 0 { 
        
        return name_win
    }
    return "Unknown-Machine"
}

get_timestamp_safe :: proc ( ) ->
                            string {
    
    t := time.now( )
    y, m, d := time.date( t )
    h, min, s := time.clock( t )
    return fmt.tprintf( "%04d-%02d-%02d %02d:%02d:%02d", y, int( m ), d, h, min, s )
}

//
// Initialization
//

init_profiler :: proc ( start_enabled : bool = true ) {
    
    global_registry.contexts = make( [ dynamic ]^Thread_Context )
    global_registry.start_time = time.tick_now( )
    global_registry.is_enabled = start_enabled
    fmt.println( "Profiler Initialized. Enabled:", start_enabled )
}

profiler_set_enabled :: proc( enabled : bool ) {
    
    global_registry.is_enabled = enabled
}

destroy_profiler :: proc ( ) {
    
    for ctx in global_registry.contexts {
        
        page := ctx.head_page
        for page != nil {
            
            next := page.next
            free( page )
            page = next
        }
        free( ctx )
    }
    delete( global_registry.contexts )
}

ensure_thread_context :: proc ( ) {
    
    t_context = new( Thread_Context )
    t_context.tid = sync.current_thread_id( )
    
    first_page := new( Event_Page )
    t_context.head_page = first_page
    t_context.curr_page = first_page

    sync.mutex_lock( & global_registry.mutex )
    append( & global_registry.contexts, t_context )
    sync.mutex_unlock( & global_registry.mutex )
}

//
// HOT PATH
//

// Note: loc is implicitly filled by the compiler.
trace :: proc ( tag : string,
                loc := #caller_location ) -> 
                string {
  
    if !global_registry.is_enabled {
        
        return ""
    }
  
    if t_context == nil { 
        
        ensure_thread_context( ) 
    }
    
    // Grab time as early as possible
    t := time.tick_now( )

    page := t_context.curr_page
    if page.count >= EVENTS_PER_PAGE {
        
        new_page           := new( Event_Page )
        page.next           = new_page
        t_context.curr_page = new_page
        page                = new_page
    }

    // We store the raw location info. We do NOT format strings here.
    // This keeps the hot path allocation-free.
    page.events[ page.count ] = Profile_Event{
        
        kind      = .Enter, 
        tag       = tag,
        loc       = loc,
        timestamp = t,
    }
    page.count += 1
    
    return tag
}

Trace_Scope :: struct { 
    
    tag : string,
    loc : runtime.Source_Code_Location, 
}

scoped_trace :: proc ( tag: string,
                       loc := #caller_location ) -> 
                       Trace_Scope {
    
    // Pass the loc explicitly to the underlying trace so it records the caller of scoped_trace
    trace( tag, loc ) 
    return Trace_Scope{ tag, loc }
}

end_trace :: proc ( s : Trace_Scope ) {
    
    if !global_registry.is_enabled {
       
       return
    }

    t := time.tick_now( )
    
    page := t_context.curr_page
    if page.count >= EVENTS_PER_PAGE {
        
        new_page           := new( Event_Page )
        page.next           = new_page
        t_context.curr_page = new_page
        page                = new_page
    }

    page.events[ page.count ] = Profile_Event{
        
        kind      = .Exit, 
        tag       = s.tag, 
        loc       = s.loc,
        timestamp = t,
    }
    page.count += 1
}

//
// Analysis and Reporting ( The Cold Path )
//

Func_Stat :: struct {
    
    full_name      : string,  // Cached combination of Tag:File:line:Func
    total_duration : i64,     // From Entry to Exit
    self_duration  : i64,     // Total - Children
    calls          : u64,
    min_time       : i64,
    max_time       : i64,
}

Span_Info :: struct {
    
    name     : string,
    start_ns : i64,
    end_ns   : i64,
    depth    : int,
}

// Struct to map raw location to a formatted string
Location_Key :: struct {
    
    file      : string,
    proc_name : string,
    tag       : string,
}

/*

generate_reports :: proc ( ) {

    if !global_registry.is_enabled {
       
       return
    }
    
    fmt.println( "Generating reports..." )
    
    sync.mutex_lock( & global_registry.mutex )
    defer sync.mutex_unlock( & global_registry.mutex )

    // 1. String Cache: Map Location Data -> Formatted String
    // This ensures we only allocate the formatted string ONCE per unique trace location.
    name_cache := make( map[ Location_Key ]string )
    defer delete( name_cache )
    
    // Function to resolve name from cache or build it
    resolve_name :: proc ( cache : ^map[ Location_Key ]string,
                           tag   : string,
                           loc   : runtime.Source_Code_Location ) ->
                           string {
                               
        key := Location_Key{ loc.file_path, loc.procedure, tag }
        
        if key in cache {
            
            return cache[ key ]
        }
        
        // Build the string : "Tag @ File @ line @ Proc"
        file_name := filepath.base( loc.file_path )
        full_str := fmt.aprintf( "%s @ %s @ %d @ %s()",
                                 tag, file_name, loc.line, loc.procedure )
        cache[ key ] = full_str
        return full_str
    }

    stats_map := make( map[ string ]Func_Stat )
    defer delete( stats_map )

    thread_spans := make( map[ int ][ dynamic ]Span_Info )
    defer {
        
        for _, v in thread_spans {
            
            delete( v )
        }
        delete( thread_spans )
    }

    global_start := global_registry.start_time
    max_end_ns : i64 = 0

    // Temporary stack item for analysis
    Stack_Item :: struct { 
    
        start : time.Tick, 
        tag   : string,
        loc   : runtime.Source_Code_Location
    }

    for ctx in global_registry.contexts {
        
        stack := make( [ dynamic ]Stack_Item )
        defer delete( stack ) 

        spans := make( [ dynamic ]Span_Info )
        thread_spans[ ctx.tid ] = spans

        curr := ctx.head_page
        for curr != nil {
            
            for i in 0 ..< curr.count {
                
                ev := curr.events[ i ]

                if ev.kind == .Enter {
                    
                    append( & stack, Stack_Item{ ev.timestamp, ev.tag, ev.loc } )
                } else {
                    
                    if len( stack ) > 0 {
                        
                        item := pop( & stack )
                        
                        // RESOLVE NAME ( Cold Path )
                        full_name := resolve_name( &name_cache, item.tag, item.loc )
                        
                        diff_tick := time.tick_diff( item.start, ev.timestamp )
                        dur_ns := time.duration_nanoseconds( diff_tick )
                        
                        stat, ok := stats_map[ full_name ]
                        if !ok {
                            
                            stat.full_name = full_name
                            stat.min_time  = max( i64 )
                        }
                        
                        stat.calls          += 1
                        stat.total_duration += dur_ns
                        
                        if dur_ns < stat.min_time {
                           
                            stat.min_time = dur_ns
                        }
                        
                        if dur_ns > stat.max_time {
                            
                            stat.max_time = dur_ns
                        }
                        
                        stats_map[ full_name ] = stat

                        start_ns := time.duration_nanoseconds( time.tick_diff( global_start, item.start ) )
                        end_ns   := time.duration_nanoseconds( time.tick_diff( global_start, ev.timestamp ) )
                        if end_ns > max_end_ns {
                            
                            max_end_ns = end_ns
                        }

                        depth := len( stack )
                        append( & thread_spans[ ctx.tid ],
                                Span_Info{
                            
                                    name     = full_name,
                                    start_ns = start_ns,
                                    end_ns   = end_ns,
                                    depth    = depth,
                        } )
                    }
                }
            }
            curr = curr.next
        }
    }

    sorted_stats := make( [ dynamic ]Func_Stat, 0, len( stats_map ) )
    for _, v in stats_map {
       
        append( & sorted_stats, v )
    }
    defer delete( sorted_stats )

    slice.sort_by( sorted_stats[ : ], proc( a, b : Func_Stat ) -> bool {
        
        return a.total_duration > b.total_duration
    } )

    write_txt_report( sorted_stats[ : ] )
    write_html_visualizer( thread_spans, max_end_ns, sorted_stats[ : ] )
}

*/

generate_reports :: proc ( ) {

    if !global_registry.is_enabled {
        
        return
    }
    
    fmt.println( "Generating reports..." )
    
    sync.mutex_lock( & global_registry.mutex )
    defer sync.mutex_unlock( & global_registry.mutex )

    // 1. String Cache
    name_cache := make( map[ Location_Key ]string )
    defer delete( name_cache )
    
    resolve_name :: proc ( cache : ^map[ Location_Key ]string,
                           tag   : string,
                           loc   : runtime.Source_Code_Location ) ->
                           string {
                              
        key := Location_Key{ loc.file_path, loc.procedure, tag }
        
        if key in cache {
            
            return cache[ key ]
        }
        
        file_name := filepath.base( loc.file_path )
        full_str := fmt.aprintf( "%s @ %s @ %d @ %s()",
                                 tag, file_name, loc.line, loc.procedure )
        cache[ key ] = full_str
        return full_str
    }

    stats_map := make( map[ string ]Func_Stat )
    defer delete( stats_map )

    thread_spans := make( map[ int ][ dynamic ]Span_Info )
    defer {
        
        for _, v in thread_spans {
            
            delete( v )
        }
        delete( thread_spans )
    }

    global_start := global_registry.start_time
    max_end_ns : i64 = 0

    // --- CHANGED: Added children_dur to track inner calls ---
    Stack_Item :: struct { 
    
        start        : time.Tick, 
        tag          : string,
        loc          : runtime.Source_Code_Location,
        children_dur : i64,  // Accumulator for children's time
    }

    for ctx in global_registry.contexts {
        
        stack := make( [ dynamic ]Stack_Item )
        defer delete( stack ) 

        spans := make( [ dynamic ]Span_Info )
        thread_spans[ ctx.tid ] = spans

        curr := ctx.head_page
        for curr != nil {
            
            for i in 0 ..< curr.count {
                
                ev := curr.events[ i ]

                if ev.kind == .Enter {
                    
                    // Init children_dur to 0
                    append( & stack, Stack_Item{ ev.timestamp, ev.tag, ev.loc, 0 } )

                } else {
                    
                    if len( stack ) > 0 {
                        
                        item := pop( & stack )
                        
                        full_name := resolve_name( &name_cache, item.tag, item.loc )
                        
                        diff_tick := time.tick_diff( item.start, ev.timestamp )
                        total_ns  := time.duration_nanoseconds( diff_tick )
                        
                        // --- CALCULATION LOGIC FIX ---
                        
                        // Self Time = Total Time - Time spent in Children
                        self_ns   := total_ns - item.children_dur
                        
                        // If there is a parent on the stack, add OUR total time to THEIR children accumulator
                        if len( stack ) > 0 {
                             
                             // Get pointer to parent (top of stack)
                             parent_idx := len( stack ) - 1
                             stack[ parent_idx ].children_dur += total_ns
                        }
                        
                        // -----------------------------
                        
                        stat, ok := stats_map[ full_name ]
                        if !ok {
                            
                            stat.full_name = full_name
                            stat.min_time  = max( i64 )
                        }
                        
                        stat.calls          += 1
                        stat.total_duration += total_ns
                        stat.self_duration  += self_ns  // Store self time
                        
                        if total_ns < stat.min_time {
                            
                            stat.min_time = total_ns
                        }
                        
                        if total_ns > stat.max_time {
                            
                            stat.max_time = total_ns
                        }
                        
                        stats_map[ full_name ] = stat

                        start_ns := time.duration_nanoseconds( time.tick_diff( global_start, item.start ) )
                        end_ns   := time.duration_nanoseconds( time.tick_diff( global_start, ev.timestamp ) )
                        if end_ns > max_end_ns {
                            
                            max_end_ns = end_ns
                        }

                        depth := len( stack )
                        append( & thread_spans[ ctx.tid ],
                                Span_Info{
                                   
                                        name     = full_name,
                                        start_ns = start_ns,
                                        end_ns   = end_ns,
                                        depth    = depth,
                        } )
                    }
                }
            }
            curr = curr.next
        }
    }

    sorted_stats := make( [ dynamic ]Func_Stat, 0, len( stats_map ) )
    for _, v in stats_map {
      
        append( & sorted_stats, v )
    }
    defer delete( sorted_stats )

    slice.sort_by( sorted_stats[ : ], proc( a, b : Func_Stat ) -> bool {
        
        return a.total_duration > b.total_duration
    } )

    write_txt_report( sorted_stats[ : ] )
    write_html_visualizer( thread_spans, max_end_ns, sorted_stats[ : ] )
}


/*
write_txt_report :: proc ( stats : [ ]Func_Stat ) {
    
    sb : strings.Builder
    strings.builder_init( & sb )
    defer strings.builder_destroy( & sb )

    hostname := get_hostname_safe( )
    now_str  := get_timestamp_safe( )
    exe_name := os.args[ 0 ]
    
    
    fmt.sbprintln( & sb, "================================================================================================================================================" )
    fmt.sbprintln( & sb, "                                    PROFILLER REPORT                                                                                            " )
    fmt.sbprintln( & sb, "================================================================================================================================================" )
    fmt.sbprintfln( & sb,  " Program:  %s", exe_name )
    fmt.sbprintfln( & sb,  " Time:     %s", now_str )
    fmt.sbprintfln( & sb,  " Machine:  %s", hostname )
    fmt.sbprintln( & sb, "================================================================================================================================================" )
    fmt.sbprintln( & sb, "" )

    // Increased width for Function column
    fmt.sbprintf( & sb,  "| %4s | %-70s | %-12s | %-13s | %-13s | %-13s |\n", "#", "Function Context", "Calls", "Total(ms)", "Avg(us)", "Max(us)" )
    fmt.sbprintln( & sb, "|------|------------------------------------------------------------------------|--------------|---------------|---------------|---------------|" )

    replace_left_zeros :: proc ( float_str : string ) ->
                                 string {
        
        counter := 0
        for elem, i in float_str {
            
            if elem == '0' && i < len( float_str ) - 1 && float_str[ i + 1 ] != '.' {
                
                counter += 1
            } else {
                
                break
            }
        }
        
        ret_str, _  := strings.replace( float_str, "0", "_", counter )
        return ret_str
    }
    
    
    for s, i in stats {
        
        total_ms := f64( s.total_duration ) / 1_000_000.0
        avg_us   := ( f64( s.total_duration ) / f64( s.calls ) ) / 1000.0
        max_us   := f64( s.max_time ) / 1000.0
        
        // Truncate name if too long for cleaner TXT output
        display_name := s.full_name
        // if len( display_name ) > 50 {
        // 
        //     display_name = display_name[ : 47 ]
        // }

        if len( display_name ) > 70 {
            
             display_name = display_name[ : 67 ]
        }

        // fmt.sbprintf( & sb, "| %4d | %-70s | %12d | %12.3f | %10.3f | %10.3f |\n", 
        //               i + 1, display_name, s.calls, total_ms, avg_us, max_us )

        
        width := 4        
        func_index_str := fmt.tprintf( "%4d", i + 1 )
        func_index_str = replace_left_zeros( func_index_str )
        
        width = 12        
        s_calls_str := fmt.tprintf( "%12d", s.calls )
        s_calls_str = replace_left_zeros( s_calls_str )
        
        width = 13        
        total_ms_str := fmt.tprintf( "%13.3f", total_ms )
        total_ms_str = replace_left_zeros( total_ms_str )
        
        width = 13        
        avg_us_str := fmt.tprintf( "%13.3f", avg_us )
        avg_us_str = replace_left_zeros( avg_us_str )
        
        width = 13        
        max_us_str := fmt.tprintf( "%13.3f", max_us)
        max_us_str = replace_left_zeros( max_us_str )
        
        fmt.sbprintf( & sb, "| %s | %-70s | %s | %s | %s | %s |\n", 
                      func_index_str, display_name, s_calls_str, total_ms_str, avg_us_str, max_us_str )
        
    }
    fmt.sbprintln( & sb, "================================================================================================================================================" )

    os.write_entire_file( "profille_report.txt", transmute( [ ]u8 )strings.to_string( sb ) )
}

*/


write_txt_report :: proc ( stats : [ ]Func_Stat ) {
    
    sb : strings.Builder
    strings.builder_init( & sb )
    defer strings.builder_destroy( & sb )

    hostname := get_hostname_safe( )
    now_str  := get_timestamp_safe( )
    exe_name := os.args[ 0 ]
    
    
    fmt.sbprintln( & sb, "================================================================================================================================================================" )
    fmt.sbprintln( & sb, "                                                                PROFILLER REPORT                                                                                " )
    fmt.sbprintln( & sb, "================================================================================================================================================================" )
    fmt.sbprintfln( & sb,  " Program:  %s", exe_name )
    fmt.sbprintfln( & sb,  " Time:     %s", now_str )
    fmt.sbprintfln( & sb,  " Machine:  %s", hostname )
    fmt.sbprintln( & sb, "================================================================================================================================================================" )
    fmt.sbprintln( & sb, "" )

    // Added Self(ms) column
    fmt.sbprintf( & sb,  "| %4s | %-70s | %-12s | %-13s | %-13s | %-13s | %-13s |\n", "#", "Function Context", "Calls", "Total(ms)", "Self(ms)", "Avg(us)", "Max(us)" )
    fmt.sbprintln( & sb, "|------|------------------------------------------------------------------------|--------------|---------------|---------------|---------------|---------------|" )

    replace_left_zeros :: proc ( float_str : string ) ->
                                 string {
       
        counter := 0
        for elem, i in float_str {
            
            if elem == '0' && i < len( float_str ) - 1 && float_str[ i + 1 ] != '.' {
                
                counter += 1
            } else {
                
                break
            }
        }
        
        ret_str, _  := strings.replace( float_str, "0", "_", counter )
        return ret_str
    }
    
    
    for s, i in stats {
        
        total_ms := f64( s.total_duration ) / 1_000_000.0
        self_ms  := f64( s.self_duration )  / 1_000_000.0  // NEW
        avg_us   := ( f64( s.total_duration ) / f64( s.calls ) ) / 1000.0
        max_us   := f64( s.max_time ) / 1000.0
        
        display_name := s.full_name

        if len( display_name ) > 70 {
            
             display_name = display_name[ : 67 ]
        }

        width := 4        
        func_index_str := fmt.tprintf( "%4d", i + 1 )
        func_index_str = replace_left_zeros( func_index_str )
        
        width = 12        
        s_calls_str := fmt.tprintf( "%12d", s.calls )
        s_calls_str = replace_left_zeros( s_calls_str )
        
        width = 13        
        total_ms_str := fmt.tprintf( "%13.3f", total_ms )
        total_ms_str = replace_left_zeros( total_ms_str )

        width = 13        
        self_ms_str := fmt.tprintf( "%13.3f", self_ms ) // NEW
        self_ms_str = replace_left_zeros( self_ms_str )
        
        width = 13        
        avg_us_str := fmt.tprintf( "%13.3f", avg_us )
        avg_us_str = replace_left_zeros( avg_us_str )
        
        width = 13        
        max_us_str := fmt.tprintf( "%13.3f", max_us)
        max_us_str = replace_left_zeros( max_us_str )
        
        fmt.sbprintf( & sb, "| %s | %-70s | %s | %s | %s | %s | %s |\n", 
                      func_index_str, display_name, s_calls_str, total_ms_str, self_ms_str, avg_us_str, max_us_str )
        
    }
    fmt.sbprintln( & sb, "================================================================================================================================================================" )

    os.write_entire_file( "profille_report.txt", transmute( [ ]u8 )strings.to_string( sb ) )
}

write_html_visualizer :: proc ( thread_data : map[ int ][ dynamic ]Span_Info,
                                max_ns      : i64,
                                stats       : [ ]Func_Stat ) {
                                    
    sb : strings.Builder
    strings.builder_init( & sb )
    defer strings.builder_destroy( & sb )

    // Standard HTML 
    exe_name := os.args[ 0 ]
    
    svg_width     := 3000
    row_height    := 24
    header_offset := 50
    
    total_content_height := 0
    
    sorted_tids := make( [ dynamic ]int, 0, len( thread_data ) )
    for tid in thread_data {
       
        append( & sorted_tids, tid )
    }
    slice.sort( sorted_tids[ : ] )
    defer delete( sorted_tids )

    thread_offsets := make( map[ int ]int )
    defer delete( thread_offsets )

    for tid in sorted_tids {
        
        spans     := thread_data[ tid ]
        max_depth := 0
        for s in spans { 
            
            if s.depth > max_depth {
               
                max_depth = s.depth
            }
        }
        thread_offsets[ tid ] = total_content_height
        total_content_height += ( max_depth + 2 ) * row_height 
    }
    
    svg_height := total_content_height + header_offset

    fmt.sbprintln( & sb, "<!DOCTYPE html><html><head><meta charset='utf-8'><title>Odin Terminal Profiller Report</title><style>" )
    fmt.sbprintln( & sb, "body { font-family: 'Segoe UI', sans-serif; background: #121212; color: #e0e0e0; margin: 0; }" )
    fmt.sbprintln( & sb, ".container { max-width: 95%; margin: 20px auto; }")
    fmt.sbprintln( & sb, ".card { background: #1e1e1e; border: 1px solid #333; border-radius: 8px; margin-bottom: 20px; }" )
    fmt.sbprintln( & sb, ".card-header { background: #252525; padding: 15px; border-bottom: 1px solid #333; } h2 { margin: 0; font-size: 18px; }" )
    fmt.sbprintln( & sb, ".card-body { padding: 20px; overflow-x: auto; }" )
    fmt.sbprintln( & sb, "rect:hover { opacity: 0.8; stroke: white; stroke-width: 1; cursor: pointer; }" )
    fmt.sbprintln( & sb, "table { width: 100%; border-collapse: collapse; font-size: 13px; }" )
    fmt.sbprintln( & sb, "th, td { text-align: left; padding: 10px; border-bottom: 1px solid #333; }" )
    fmt.sbprintln( & sb, "th { background-color: #2d2d2d; }" )
    fmt.sbprintln( & sb, "</style></head><body><div class='container'>" ) 

    // Timeline
    fmt.sbprintln( & sb, "<div class='card'><div class='card-header'><h2>Timeline</h2></div><div class='card-body' style='padding:0;'>" )
    fmt.sbprintf( & sb, "<svg width='%d' height='%d' style='background:#181818; display:block;'>",
                  svg_width, svg_height )

    // Time Grid
    grid_ns : i64 = max_ns / 20
    
    if grid_ns == 0  {
        
        grid_ns = 1
    }
    
    for t := i64( 0 ); t <= max_ns; t += grid_ns {
        
        x := int( ( f64( t ) / f64( max_ns ) ) * f64( svg_width ) )
        fmt.sbprintf( & sb, 
                      "<line x1='%d' y1='%d' x2='%d' y2='%d' stroke='#333' stroke-dasharray='4'/>",
                      x, header_offset, x, svg_height )
        fmt.sbprintf( & sb,
                      "<text x='%d' y='%d' fill='#666' font-size='10'>%.1f ms</text>",
                      x + 4, header_offset - 10, f64( t ) / 1e6 )
    }

    for tid in sorted_tids {
        
        spans  := thread_data[ tid ]
        base_y := thread_offsets[ tid ] + header_offset
        fmt.sbprintf( & sb,
                      "<text x='10' y='%d' fill='#aaa' font-weight='bold'>Thread %d</text>", 
                      base_y + 16, tid )
        fmt.sbprintf( & sb, 
                      "<line x1='0' y1='%d' x2='%d' y2='%d' stroke='#444'/>", 
                      base_y, svg_width, base_y )

        for s in spans {
            
            if ( s.end_ns - s.start_ns ) < MIN_DRAW_NS {
               
                continue
            }
            x := int( ( f64( s.start_ns ) / f64( max_ns ) ) * f64( svg_width ) )
            w := int( ( f64( s.end_ns - s.start_ns ) / f64( max_ns ) ) * f64( svg_width ) )
            if w < 1 {
                
                w = 1
            }
            y := base_y + ( ( s.depth + 1 ) * row_height )
            color := get_color_hex( s.name )
            
            // Clean name for display on bar ( remove file info for space )
            short_name  := s.name
            bracket_idx := strings.index( short_name, "[" )
            if bracket_idx > 0 {
                
                short_name = short_name[ : bracket_idx - 1 ]
            }

            fmt.sbprintf( & sb,
                          "<g><rect x='%d' y='%d' width='%d' height='%d' fill='%s' rx='2'>",
                          x, y, w, row_height - 4, color )
            
            // Full name in tooltip
            fmt.sbprintf( & sb,
                          "<title>%s&#10;Time: %.3f ms</title></rect>", 
                           s.name, f64( s.end_ns - s.start_ns ) / 1e6 )
            
            if w > 50 {
                
                fmt.sbprintf( & sb,
                              "<text x='%d' y='%d' fill='#000' font-size='10' font-weight='bold' clip-path='inset(0 0 0 0)'>%s</text>",
                              x + 4, y + 14, short_name )
            }
            
            fmt.sbprint( & sb, "</g>" )
        }
    }
    
    fmt.sbprintln( & sb, "</svg></div></div>" )

    // Stats Table
    fmt.sbprintln( & sb, "<div class='card'><div class='card-header'><h2>Function Statistics</h2></div><div class='card-body'>" )
    fmt.sbprintln( & sb, "<table><thead><tr><th>#</th><th>Function Context</th><th>Calls</th><th>Total Time</th><th>Avg Time</th><th>Max Time</th></tr></thead><tbody>" )
    
    for s, i in stats {
        
         fmt.sbprintf( & sb, "<tr><td>%d</td><td>%s</td><td>%d</td><td>%.3f ms</td><td>%.3f us</td><td>%.3f us</td></tr>", 
                       i + 1,
                       s.full_name,
                       s.calls,
                       f64( s.total_duration ) / 1e6,
                       ( f64( s.total_duration ) / f64( s.calls ) ) /1e3,
                       f64( s.max_time ) / 1e3 )
    }
    
    fmt.sbprintln( & sb, "</tbody></table></div></div></div></body></html>" )

    os.write_entire_file( "profille_report.html",
                           transmute( [ ]u8 )strings.to_string( sb ) )
}

get_color_hex :: proc( name : string ) -> string {
    
    h: u32 = 5381
    for b in name { 
        
        h = ( ( h << 5 ) + h ) + u32( b )
    }
    colors := [?]string{ "#ef5350",
                         "#ec407a",
                         "#ab47bc",
                         "#7e57c2",
                         "#5c6bc0",
                         "#42a5f5",
                         "#29b6f6",
                         "#26c6da",
                         "#26a69a",
                         "#66bb6a",
                         "#9ccc65",
                         "#d4e157",
                         "#ffee58",
                         "#ffca28",
                         "#ffa726",
                         "#ff7043" }
    
    return colors[ h % u32( len( colors ) ) ]
}


//---------------------------------------------------------------------------------------

//
// Test example
// 




/*

// IMPORTANT : The defer reodering of instructions by the compiler is the problem,
//             we can't use the defer at the beggining of the function to time it,
//             we must use the 
//  
//               trace( ) 
// 
//                  // Function code is HERE
// 
//               end_trace()


// @(optimization_mode="none")
heavy_math :: #force_no_inline proc ( val : f64 ) ->
                                      f64 {
    
    defer end_trace( scoped_trace( "Math Op" ) ) 
    
    x : f64 = val
    
    for i in 0 ..< 10_000_000 {
        
        if i == 0 { fmt.printf("") }
        
        x += math.sin( f64( i ) ) + math.cos( f64( i ) )
    }
    
    return x
}

*/



/*

// 1º Option without defer - WORKS CORRECTLY

heavy_math :: proc ( val : f64 ) ->
                     f64 {
    
    MATH_OP :: "Math Op"
    trace( MATH_OP )
    
    // Start HERE
                         

    x : f64 = val
    
    for i in 0 ..< 10_000_000 {
        
        x += math.sin( f64( i ) ) + math.cos( f64( i ) )
    }

    
    // End HERE
    
    end_trace( Trace_Scope{ tag = MATH_OP } )

    
    return x
}

*/



// 2º Option without defer - WORKS CORRECTLY

// We are going to remove the defer, we will handle it with code logic manually.
heavy_math :: proc ( val : f64 ) ->
                     f64 {
    
    f_scope := scoped_trace( "Math Op" ) 
    
    // Start HERE
    
    x : f64 = val
    
    for i in 0 ..< 10_000_000 {
        
        x += math.sin( f64( i ) ) + math.cos( f64( i ) )
    }
    
    
    // End HERE
    
    end_trace( f_scope )
    
    return x
}



worker_proc :: proc ( t : ^thread.Thread ) {

    f_scope := scoped_trace( "Thread Run" ) 

    
    y : f64 = 0
    for i in 0 ..< 100 {
    
        i_scope := scoped_trace( "Loop Iteration" ) 

        y += heavy_math( f64( i ) )
        // time.sleep( 10 * time.Millisecond )

        end_trace( i_scope )    // Manually ending inner i_scope
    
    }
    
    fmt.printfln( "The value y : %f", y )
    
    
    end_trace( f_scope )    // Manually ending the function time f_scope
}

test_example_main :: proc ( ) {

    // init_profiler( start_enabled = false )
    init_profiler( start_enabled = true )
    defer destroy_profiler( )

    // Manually control the Main scope.
    f_main_scope := scoped_trace( "Main Execution" )

    fmt.println( "Starting 5 Thread Simulation..." )
    
    threads := make( [ dynamic ]^thread.Thread )
    defer delete( threads )

    num_threads := 5
    
    for i in 0 ..< num_threads {
        
        t := thread.create( worker_proc )
        append( & threads, t )
        thread.start( t )
    }

    z : f64 = 0
    
    // Do some work on main thread
    for i in 0 ..< 3 {
        
        z += heavy_math( f64( i ) )
        time.sleep( 20 * time.Millisecond )
    }

    fmt.printfln( "z : %f", z )
    
    for t in threads {
        
        thread.join( t )
        thread.destroy( t )
    }

    fmt.println( "Simulation Done." )
    
    
    // IMPORTANT:
    //   Close the main scope explicitly here.
    //   If we don't close, this time will not appear in the final report,
    //   the all entry for this function willnot appear.
    end_trace( f_main_scope )

    // Now generate reports ( Main will be visible, because we end_trace( )  and close it. )
    generate_reports( )
    
}

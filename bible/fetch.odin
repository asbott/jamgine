package bible

import "vendor:http/client"
import "vendor:http/openssl"

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:strconv"
import "core:time"

Book_Name :: enum {
    Genesis, Exodis, Leviticus, Numbers, Deuteronomy,

    Joshua, Judges, Ruth, 
    Samuel1, Samuel2, Kings1, Kings2, Chronicles1, Chronicles2,

    Ezra, Nehemiah, Esther, Job,

    Psalms, Proverbs, Ecclesiastes, Song_Of_Solomon, Isaiah,
    Jeremiah, Lamentations, Ezekiel,
    Daniel, Hosea, Joel, Amos, Obadiah,
    Jonah, Micah, Nahum, Habakkuk,
    Zephanaiah, Haggai, Zecharaiah, Malachi,

    Esdras1, Esdras2, Tobit, Judith, Rest_Of_Esther,
    Wisdom, Ecclesiasticus, Baruch, 
    Maccabees1, Maccabees2,

    Matthew, Mark, Luke, John,
    The_Acts, Romans,
    Corinthians1,Corinthians2,
    Galatians, Ephesians, Philippians,
    Colossians, Thesselonians1, Thesselonians2,
    Timothy1, Timothy2, Titus, Philemon,
    Hebrews, James, Peter,
    John1, John2, John3,
    Jude,
    Revelation,
}

BIBLE_TRANSLATION :: "en-kjv"

Bible :: struct {
    books : [len(Book_Name)]Book,
}
Book :: struct {
    name : Book_Name,
    chapters : [dynamic]Chapter,
    display_text : string,
    num_chars : int,

    downloaded : bool,
}
Chapter :: struct {
    verses : [dynamic]string,
    display_text : string,
    num_chars : int,

    downloaded : bool,
}

bible : Bible;

request_json :: proc(endpoint : string, allocator := context.allocator) -> (json.Object, bool) {
    context.logger = {};
    context.allocator = allocator;
    res, err := client.get(endpoint);
	if err != nil {
		fmt.printf("Request failed: %s", err)
		return nil, false;
	}
	defer client.response_destroy(&res)
    
	body, allocation, berr := client.response_body(&res)
	if berr != .None {
		fmt.printf("Error retrieving response body: %s", berr)
		return nil, false;
	}
	defer client.body_destroy(body, allocation)

    plain_text := body.(client.Body_Plain);
    json_obj, json_err := json.parse_string(plain_text);
    
    if json_err != .None {
        fmt.println("Failed json parse");
        return nil, false;
    }

    return json_obj.(json.Object);
}

get_verse :: proc(book : Book_Name, chapter, verse : int) -> (verse_text : string, verse_ok : bool) {

    downloaded_chapters := &bible.books[int(book)].chapters;
    if chapter >= len(downloaded_chapters) || !downloaded_chapters[chapter].downloaded {
        if chapter >= len(downloaded_chapters) do resize(downloaded_chapters, chapter+1);
        downloaded_chapters[chapter] = get_chapter(book, chapter) or_return;
    }

    chap := downloaded_chapters[chapter];

    if verse >= len(chap.verses) do return "Verse number out of range", false;

    return chap.verses[verse], true;
}

download_chapter :: proc(book_name : Book_Name, lookup_chapter_num : int) -> (Chapter, bool) {
    book := &bible.books[int(book_name)];
    if lookup_chapter_num < len(book.chapters) && book.chapters[lookup_chapter_num].downloaded {
        return book.chapters[lookup_chapter_num], true;
    }

    req_string := fmt.tprintf("https://raw.githubusercontent.com/wldeh/bible-api/main/bibles/%s/books/%s/chapters/%i.json", BIBLE_TRANSLATION, strings.to_lower(fmt.tprint(book_name)), lookup_chapter_num);
    obj, ok := request_json(req_string, context.temp_allocator);

    if ok {
        chapters_obj := obj["data"].(json.Array);
        if book.chapters == nil do book.chapters = make([dynamic]Chapter);
        if lookup_chapter_num >= len(book.chapters) do resize(&book.chapters, lookup_chapter_num+1);
        
        chapter := &book.chapters[lookup_chapter_num];

        for untyped_obj in chapters_obj {
            chapter_obj := untyped_obj.(json.Object);

            chapter_num_string := chapter_obj["chapter"].(json.String);
            verse_num_string := chapter_obj["verse"].(json.String);

            chapter_num, parse_ok1 := strconv.parse_int(chapter_num_string);
            verse_num, parse_ok2 := strconv.parse_int(verse_num_string);
            assert(parse_ok1 && parse_ok2);
            assert(chapter_num == lookup_chapter_num);

            verse_text := chapter_obj["text"].(json.String);
            if chapter.verses == nil do chapter.verses = make([dynamic]string);
            if verse_num >= len(chapter.verses) do resize(&chapter.verses, verse_num+1);
            
            chapter.verses[verse_num] = strings.clone(verse_text);
            chapter.num_chars += len(verse_text);
        }

        chapter.downloaded = true;
        return chapter^, true;
    } else {
        return {}, false;
    }
}

get_chapter :: proc(book_name : Book_Name, lookup_chapter_num : int) -> (chapter : Chapter, success : bool) {
    book := get_book(book_name) or_return;
    if lookup_chapter_num >= len(book.chapters) do return {}, false;
    fmt.println(book.chapters[lookup_chapter_num]);
    return book.chapters[lookup_chapter_num], true;
}

get_book :: proc(book_name : Book_Name) -> (book : Book, success: bool) {
    if !bible.books[int(book_name)].downloaded {

        sw : time.Stopwatch;
        time.stopwatch_start(&sw);

        book := &bible.books[int(book_name)];

        chapter_num := 0;

        for true {
            chapter_num += 1;
            if chapter_num < len(book.chapters) && book.chapters[chapter_num].downloaded do continue;

            _, ok := download_chapter(book_name, chapter_num);

            if !ok {
                if chapter_num <= 1 do success = false;
                else do success = true;
                break;
            }

            book.num_chars += book.chapters[chapter_num].num_chars;
        }

        fmt.printf("Downloading the Book of %s took %fs\n", book_name, time.duration_seconds(time.stopwatch_duration(sw)));
        
        sw = {};
        time.stopwatch_start(&sw);
        
        builder : strings.Builder;
        strings.builder_init(&builder, 0, book.num_chars);
        for chapter, ci in book.chapters[1:] {
            fmt.sbprintln(&builder, "\n\t----Chapter ", ci+1, "----", sep="");
            start_index := strings.builder_len(builder);
            for ver,i in chapter.verses[1:] {
                fmt.sbprint(&builder, "[", i+1, "] ", ver, "  ", sep="");
            }

            book.chapters[ci+1].display_text = strings.to_string(builder)[start_index:];
        }
        book.display_text = strings.to_string(builder);
        
        fmt.printf("Formatting the Book of %s took %fs\n", book_name, time.duration_seconds(time.stopwatch_duration(sw)));

        book.downloaded = true;
    } else do success = true;

    return bible.books[int(book_name)], success;
}
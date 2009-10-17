/* Soiled - The flash mud client.
   Copyright 2007-2009 Sebastian Andersson

   This program is free software: you can redistribute it and/or modify
   it under the terms of the GNU General Public License as published by
   the Free Software Foundation, either version 3 of the License, or
   (at your option) any later version.

   This program is distributed in the hope that it will be useful,
   but WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
   GNU General Public License for more details.

   You should have received a copy of the GNU General Public License
   along with this program.  If not, see <http://www.gnu.org/licenses/>.

   Contact information is located here: <http://bofh.diegeekdie.com/>
*/

package wordCache;

/** WordCache stores words and the frequency of them. It can
    retrieve word-completions by a prefix. **/
class WordCacheBase
{
    private static var WORD_CACHE_SIZE = 64;

    /* The words are stored in WordEntry objects
        that are stored in different buckets
	depending on the first character of the word.
    */
    private var words : Array<Array<WordEntry>>;

    public function new(?other : WordCacheBase)
    {
	if(other != null) {
	    words = other.words;
	} else {
	    words = new Array<Array<WordEntry>>();
	    words[WORD_CACHE_SIZE-1] = null;
	    for(i in 0...WORD_CACHE_SIZE) {
		words[i] = new Array<WordEntry>();
	    }
	}
    }

    private function getBucket(prefix : String) : Array<WordEntry>
    {
	var i = prefix.charCodeAt(0) % WORD_CACHE_SIZE;
	return words[i];
    }

    /* A word comparer, used to sort and find words in the list */
    private function wordCompare(word : String, ent : WordEntry)
    {
	if(word == ent.word) return 0;
	if(word < ent.word) return -1;
	return 1;
    }

    /* A prefix comparer, used to lookup words in the list */
    private function prefixCompare(prefix : String, ent : WordEntry)
    {
	var sw = ent.word.substr(0, prefix.length);
	if(prefix == sw) return 0;
	if(prefix < sw) return -1;
	return 1;
    }

    /* Lookup the WordEntry's index in the bucket via a
       supplied comparator. Returns -1 if no entry was found. */
    private function lookup(b : Array<WordEntry>,
	                    prefix : String,
	                    comp : String->WordEntry -> Int) : Int
    {
	var i = lookupIP(b, prefix, comp);
	if(i >= b.length) return -1; // Not found.
	if(comp(prefix, b[i]) == 0) return i;
	return -1; // Not found.
    }

    /* Lookup the WordEntry's index in the bucket via a
       supplied comparator. Returns the insertion point if none was found. */
    private function lookupIP(b : Array<WordEntry>,
	                      word : String,
	                      comp : String->WordEntry -> Int) : Int
    {
	var rMax : Int = b.length;
	var max = rMax;
	if(max == 0) return 0;
	var min : Int = 0;
	var i = max>>1;
	while(true) {
	    var v = comp(word, b[i]);
	    if(v == 0) return i; // A match.
	    if(v > 0) min = i;
	    else max = i;
	    var new_i = (max+min)>>1;
	    if(new_i == i) { // No change, the end is here.
		if(v > 0) {
		    return i+1;
		}
		return i;
	    }
	    i = new_i;
	}
	return 0;
    }

    public function add(word)
    {
	if(word == "") return;
	var b = getBucket(word);
	// Find the word.
	var i = lookupIP(b, word, wordCompare);
	if(i >= b.length) {
	    b.push( { word : word, frequency : 1 } );
	    return;
	} else if(b[i].word != word) {
	    b.insert(i, { word : word, frequency : 1 } );
	} else {
	    b[i].frequency++;
	}
    }

    public function get(prefix : String, num : Int) : String
    {
	throw "This method should not be called.";
	return "";
    }
}

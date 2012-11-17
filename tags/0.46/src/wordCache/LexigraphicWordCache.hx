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

class LexigraphicWordCache extends WordCacheBase
{
    public override function get(prefix : String, num : Int) : String
    {
	if(prefix == "") return "";
	var b = getBucket(prefix);
	var i = lookup(b, prefix, prefixCompare);
	if(i == -1) return null;
	var first = i;
	while(first > 0 && prefixCompare(prefix, b[first-1]) == 0) first--;
	i = first + num;
	if(i >= b.length || prefixCompare(prefix, b[i]) != 0) return null;
	return b[i].word;
    }
}

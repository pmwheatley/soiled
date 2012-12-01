/* Soiled - The flash mud client.
   Copyright 2012 Sebastian Andersson

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

/*
    A simple timer. Only encapsulates flash's timer object.
*/
class Timer
{
    private var timer : flash.utils.Timer;

    private var timeoutHandler : Void -> Void;

    public function new(delay : Int,
	                repeatCount : Int,
			timeoutHandler : Void -> Void)
    {
	this.timeoutHandler = timeoutHandler;
	timer = new flash.utils.Timer(delay, repeatCount);
	timer.addEventListener("timer", onTimeout);
    }
    
    public function reset()
    {
	timer.reset();
    }

    public function start()
    {
	timer.start();
    }

    public function stop()
    {
	timer.stop();
    }

    private function onTimeout(o : Dynamic)
    {
        timeoutHandler();
    }

}

import React, { useState } from 'react';
import { supabase } from '../lib/supabase';
import { Link, useNavigate } from 'react-router-dom';

const NTRP_OPTIONS = ['1.0', '1.5', '2.0', '2.5', '3.0', '3.5', '4.0', '4.5', '5.0', '5.5', '6.0'];

export default function SignUp() {
    const [loading, setLoading] = useState(false);
    const [formData, setFormData] = useState({
        email: '',
        password: '',
        name: '',
        phone: '',
        gender: 'M',
        ntrp: '2.5',
    });

    const handleChange = (e: React.ChangeEvent<HTMLInputElement | HTMLSelectElement>) => {
        setFormData({ ...formData, [e.target.name]: e.target.value });
    };

    const handleSignUp = async (e: React.FormEvent) => {
        e.preventDefault();
        setLoading(true);

        try {
            const { error } = await supabase.auth.signUp({
                email: formData.email,
                password: formData.password,
                options: {
                    data: {
                        name: formData.name,
                        phone: formData.phone,
                        gender: formData.gender,
                        ntrp: parseFloat(formData.ntrp),
                    },
                },
            });

            if (error) throw error;
            alert('Sign up successful! Check your email for verification.');
        } catch (error: any) {
            alert(error.message);
        } finally {
            setLoading(false);
        }
    };

    return (
        <div className="h-full w-full flex items-center justify-center bg-slate-900 p-4">
            {/* Glass Card */}
            <div className="w-full max-w-md bg-white/10 backdrop-blur-md border border-white/20 rounded-2xl shadow-2xl p-8">
                <h2 className="text-3xl font-bold text-center text-white mb-2">Join RallyGoGo</h2>
                <p className="text-center text-gray-400 mb-8">Create your player profile</p>

                <form onSubmit={handleSignUp} className="space-y-5">
                    {/* Email */}
                    <div>
                        <label className="block text-sm font-medium text-gray-300 mb-1.5">Email</label>
                        <input
                            name="email"
                            type="email"
                            required
                            className="w-full px-4 py-2.5 bg-slate-800/50 backdrop-blur-sm border border-slate-700 rounded-xl text-white focus:outline-none focus:ring-2 focus:ring-[#84CC16] focus:border-transparent transition"
                            onChange={handleChange}
                        />
                    </div>

                    {/* Password */}
                    <div>
                        <label className="block text-sm font-medium text-gray-300 mb-1.5">Password</label>
                        <input
                            name="password"
                            type="password"
                            required
                            className="w-full px-4 py-2.5 bg-slate-800/50 backdrop-blur-sm border border-slate-700 rounded-xl text-white focus:outline-none focus:ring-2 focus:ring-[#84CC16] focus:border-transparent transition"
                            onChange={handleChange}
                        />
                    </div>

                    {/* Name */}
                    <div>
                        <label className="block text-sm font-medium text-gray-300 mb-1.5">Full Name</label>
                        <input
                            name="name"
                            type="text"
                            required
                            className="w-full px-4 py-2.5 bg-slate-800/50 backdrop-blur-sm border border-slate-700 rounded-xl text-white focus:outline-none focus:ring-2 focus:ring-[#84CC16] focus:border-transparent transition"
                            onChange={handleChange}
                        />
                    </div>

                    {/* Phone */}
                    <div>
                        <label className="block text-sm font-medium text-gray-300 mb-1.5">Phone</label>
                        <input
                            name="phone"
                            type="tel"
                            required
                            placeholder="010-1234-5678"
                            className="w-full px-4 py-2.5 bg-slate-800/50 backdrop-blur-sm border border-slate-700 rounded-xl text-white focus:outline-none focus:ring-2 focus:ring-[#84CC16] focus:border-transparent transition"
                            onChange={handleChange}
                        />
                    </div>

                    <div className="grid grid-cols-2 gap-4">
                        {/* Gender */}
                        <div>
                            <label className="block text-sm font-medium text-gray-300 mb-1.5">Gender</label>
                            <div className="flex items-center space-x-4 h-[46px] px-4 bg-slate-800/50 border border-slate-700 rounded-xl">
                                <label className="flex items-center space-x-2 cursor-pointer group">
                                    <input
                                        type="radio"
                                        name="gender"
                                        value="M"
                                        checked={formData.gender === 'M'}
                                        onChange={handleChange}
                                        className="text-[#84CC16] focus:ring-[#84CC16] bg-slate-700 border-slate-500"
                                    />
                                    <span className="text-gray-300 group-hover:text-white transition">Male</span>
                                </label>
                                <label className="flex items-center space-x-2 cursor-pointer group">
                                    <input
                                        type="radio"
                                        name="gender"
                                        value="F"
                                        checked={formData.gender === 'F'}
                                        onChange={handleChange}
                                        className="text-[#84CC16] focus:ring-[#84CC16] bg-slate-700 border-slate-500"
                                    />
                                    <span className="text-gray-300 group-hover:text-white transition">Female</span>
                                </label>
                            </div>
                        </div>

                        {/* NTRP */}
                        <div>
                            <label className="block text-sm font-medium text-gray-300 mb-1.5">
                                NTRP
                                <span className="ml-1 text-xs text-gray-400 group relative cursor-help">
                                    (?)
                                    <div className="absolute bottom-full right-0 mb-2 w-56 p-3 bg-black/90 backdrop-blur text-xs text-gray-200 rounded-lg border border-white/10 hidden group-hover:block z-10 shadow-xl leading-relaxed">
                                        NTRP is a rating system to classify tennis skill levels (1.0 = Beginner, 7.0 = Pro)
                                    </div>
                                </span>
                            </label>
                            <div className="relative">
                                <select
                                    name="ntrp"
                                    className="w-full px-4 py-2.5 bg-slate-800/50 backdrop-blur-sm border border-slate-700 rounded-xl text-white focus:outline-none focus:ring-2 focus:ring-[#84CC16] focus:border-transparent transition appearance-none cursor-pointer"
                                    onChange={handleChange}
                                    value={formData.ntrp}
                                >
                                    {NTRP_OPTIONS.map((val) => (
                                        <option key={val} value={val} className="bg-slate-900 text-gray-200">
                                            {val}
                                        </option>
                                    ))}
                                </select>
                                <div className="absolute right-3 top-1/2 -translate-y-1/2 pointer-events-none text-gray-400">
                                    ▼
                                </div>
                            </div>
                        </div>
                    </div>

                    <button
                        type="submit"
                        disabled={loading}
                        className="w-full py-3.5 bg-[#84CC16] hover:bg-[#65a30d] text-white font-bold rounded-xl transition duration-300 shadow-lg shadow-lime-500/20 transform hover:scale-[1.02] active:scale-[0.98] disabled:opacity-50 disabled:cursor-not-allowed mt-4"
                    >
                        {loading ? 'Creating Account...' : 'Sign Up'}
                    </button>
                </form>

                <div className="mt-6 text-center">
                    <p className="text-gray-400 text-sm">
                        Already have an account?{' '}
                        <Link to="/" className="text-[#84CC16] hover:text-[#a3e635] font-semibold transition">
                            Log In
                        </Link>
                    </p>
                </div>
            </div>
        </div>
    );
}
